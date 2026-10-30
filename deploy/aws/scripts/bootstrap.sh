#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs ON THE EC2 INSTANCE as root. Do not run it on your laptop.
#   - First boot: called by the CloudFormation UserData after it clones the fork.
#   - Later: called by scripts/apply-config.sh (through SSM Run Command) after it checks
#     out the configured ref. Safe to re-run; on-disk telemetry is kept.
#
# Reads /etc/otel-demo.env (ENV_NAME, AWS_REGION, written by UserData) and the JSON
# parameter /<ENV_NAME>/otel-demo/config (written by the stack).
# Log: /var/log/otel-demo-setup.log. The last line is "OTEL DEMO SETUP DONE" on success.
set -euxo pipefail

# shellcheck disable=SC1091
. /etc/otel-demo.env
: "${ENV_NAME:?}" "${AWS_REGION:?}"

REPO_DIR=/opt/otel-demo
JAEGER_DATA=/var/lib/otel-demo/jaeger
JAEGER_UID=10001   # user the jaegertracing/jaeger image runs as
MARK_BEGIN="# --- BEGIN deploy/aws/scripts/bootstrap.sh ---"
MARK_END="# --- END deploy/aws/scripts/bootstrap.sh ---"

param() { aws ssm get-parameter --region "$AWS_REGION" --name "/$ENV_NAME/otel-demo/$1" \
            --query Parameter.Value --output text; }
CFG=$(param config)
cfg() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$CFG" "$1"; }
DEMO_VERSION=$(cfg demoVersion)
COMPOSE_VERSION=$(cfg composeVersion)
TELEMETRY_BUCKET=$(cfg telemetryBucket)
LOCAL_RETENTION_DAYS=$(cfg localRetentionDays)

# ---------- Docker + Compose plugin ----------
dnf install -y docker
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
  "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version

# ---------- Swap (headroom for the ~7.3 GiB of container limits on 8 GiB) ----------
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cd "$REPO_DIR"

# ---------- Wait for the public URL (created by the stack with the distribution) ----------
until APP_URL=$(param app-url); do sleep 20; done

# ---------- Variables for compose.aws.yaml, in a block replaced on every run ----------
# Images are pinned to DEMO_VERSION; browser (RUM) spans go to the public URL instead of
# each visitor's own localhost.
touch .env.override
sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" .env.override
cat >> .env.override <<EOF
${MARK_BEGIN}
DEMO_VERSION=${DEMO_VERSION}
PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=${APP_URL}/otlp-http/v1/traces
LOCAL_RETENTION_DAYS=${LOCAL_RETENTION_DAYS}
BADGER_SPAN_TTL=$((LOCAL_RETENTION_DAYS * 24))h
TELEMETRY_BUCKET=${TELEMETRY_BUCKET}
AWS_REGION=${AWS_REGION}
${MARK_END}
EOF

# ---------- Jaeger Badger directory (bind mount must be writable by the container user) ----------
mkdir -p "$JAEGER_DATA/keys" "$JAEGER_DATA/values"
chown -R "$JAEGER_UID:$JAEGER_UID" "$JAEGER_DATA"

# ---------- Helper so operators run compose with the same files ----------
cat > /usr/local/bin/otel-demo-compose <<'EOF'
#!/usr/bin/env bash
# Usage: sudo otel-demo-compose ps | logs -f jaeger | restart otel-collector | ...
cd /opt/otel-demo && exec docker compose --env-file .env --env-file .env.override \
  -f compose.yaml -f compose.observability.yaml -f compose.extras.yaml \
  -f deploy/aws/config/compose.aws.yaml "$@"
EOF
chmod +x /usr/local/bin/otel-demo-compose

# ---------- Start, or recreate only the containers whose config changed ----------
otel-demo-compose up --detach --remove-orphans
otel-demo-compose ps

# ---------- OpenSearch: delete daily otel-logs-* indices after LOCAL_RETENTION_DAYS ----------
for _ in $(seq 1 60); do
  docker exec opensearch curl -sf localhost:9200/_cluster/health >/dev/null 2>&1 && break
  sleep 10
done
POLICY=$(cat <<EOF
{"policy":{"description":"otel-logs retention","default_state":"hot",
 "states":[{"name":"hot","actions":[],"transitions":[{"state_name":"delete","conditions":{"min_index_age":"${LOCAL_RETENTION_DAYS}d"}}]},
           {"name":"delete","actions":[{"delete":{}}],"transitions":[]}],
 "ism_template":[{"index_patterns":["otel-logs-*"],"priority":100}]}}
EOF
)
# A re-run gets a version conflict here if the policy exists; delete it in OpenSearch
# first if you changed LOCAL_RETENTION_DAYS and need the new value for logs.
docker exec opensearch curl -s -XPUT localhost:9200/_plugins/_ism/policies/otel-logs-retention \
  -H 'Content-Type: application/json' -d "$POLICY" || echo "WARN: ISM policy not created"
docker exec opensearch curl -s -XPOST 'localhost:9200/_plugins/_ism/add/otel-logs-*' \
  -H 'Content-Type: application/json' -d '{"policy_id":"otel-logs-retention"}' || true

echo "OTEL DEMO SETUP DONE"
