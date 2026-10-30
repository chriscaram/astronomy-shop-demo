#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Apply config changes to the RUNNING instance without replacing it (on-disk telemetry is
# kept). Use after you push changes to deploy/aws/config or scripts/bootstrap.sh, or after
# deploy.sh changed REPO_REF, DEMO_VERSION or LOCAL_RETENTION_DAYS. deploy.sh runs this
# automatically when it updates an existing environment.
#   deploy/aws/scripts/apply-config.sh deploy/aws/envs/dev.env
#
# Through SSM Run Command, the instance fetches the ref named in /<env>/otel-demo/config,
# checks it out and re-runs bootstrap.sh. Docker Compose recreates only changed containers.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"
check_account

IID=$(stack_output "$APP_STACK" InstanceId)
[ -n "$IID" ] || die "no InstanceId output on $APP_STACK"

# Runs on the instance. Values come from SSM on the instance, not from this laptop.
read -r -d '' REMOTE <<'EOF' || true
set -euo pipefail
. /etc/otel-demo.env
CFG=$(aws ssm get-parameter --region "$AWS_REGION" --name "/$ENV_NAME/otel-demo/config" --query Parameter.Value --output text)
get() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$CFG" "$1"; }
cd /opt/otel-demo
git remote set-url origin "$(get repoUrl)"
git fetch --depth 1 origin "$(get repoRef)"
git checkout -f FETCH_HEAD
bash deploy/aws/scripts/bootstrap.sh >> /var/log/otel-demo-setup.log 2>&1
tail -n 3 /var/log/otel-demo-setup.log
EOF

PARAMS=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["1800"]}))' "$REMOTE")
info "Re-running bootstrap on $IID (takes 1-10 minutes)"
CMD_ID=$(awsc ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --comment "otel-demo apply-config ($ENV_NAME)" --parameters "$PARAMS" \
  --query Command.CommandId --output text)

# The CLI waiter gives up after ~100 s, so poll instead.
for _ in $(seq 1 120); do
  STATUS=$(awsc ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
             --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed) sleep 15 ;; *) break ;; esac
done
awsc ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
[ "$STATUS" = "Success" ] || die "apply-config ended with status $STATUS. See /var/log/otel-demo-setup.log on the instance."
info "Config applied."
