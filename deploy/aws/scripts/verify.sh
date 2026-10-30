#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Read-only checks of a deployed environment. Exit code 0 only if every check passes.
#   deploy/aws/scripts/verify.sh deploy/aws/envs/dev.env
set -uo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"
check_account

DOMAIN=$(stack_output "$APP_STACK" DistributionDomain)
[ -n "$DOMAIN" ] || die "stack $APP_STACK has no DistributionDomain output. Did deploy.sh finish?"
U="https://$DOMAIN"
FAIL=0

check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 (expected $2, got $3)"; FAIL=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$U$1"; }

echo "Checking $U"
check "stack status" UPDATE_COMPLETE_OR_CREATE_COMPLETE "$(
  s=$(awsc cloudformation describe-stacks --stack-name "$APP_STACK" --query 'Stacks[0].StackStatus' --output text)
  case "$s" in CREATE_COMPLETE|UPDATE_COMPLETE) echo UPDATE_COMPLETE_OR_CREATE_COMPLETE;; *) echo "$s";; esac)"

# Public storefront
check "storefront /"                200 "$(code /)"
check "product API /api/products"   200 "$(code /api/products)"

# Admin tools redirect to the Cognito login
for p in /grafana/ /jaeger/ui/ /feature/ /loadgen/ /telemetry/; do
  loc=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 20 "$U$p")
  case "$loc" in *amazoncognito.com/oauth2/authorize*) r=login;; *) r="$(code "$p") ${loc:-no-redirect}";; esac
  check "admin $p requires login" login "$r"
done

# Blocked paths and bypass attempts
for p in /opamp/ //Grafana/ /%67rafana/ /GRAFANA/; do
  check "blocked $p" 403 "$(code "$p")"
done

# Browser telemetry endpoint points at the public URL
if curl -s --max-time 20 "$U/" | grep -q "$U/otlp-http/v1/traces"; then
  echo "PASS  page sends browser spans to $U/otlp-http/"
else
  echo "FAIL  page does not reference $U/otlp-http/v1/traces"; FAIL=1
fi

# Instance reachable by SSM
IID=$(stack_output "$APP_STACK" InstanceId)
check "SSM agent online ($IID)" Online "$(awsc ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$IID" --query 'InstanceInformationList[0].PingStatus' --output text)"

# S3 archive receiving data in the last hour (needs ~2 minutes after the Collector starts)
BUCKET=$(stack_output "$APP_STACK" TelemetryBucketName)
HOUR_PREFIX=$(date -u +'year=%Y/month=%m/day=%d/hour=%H')
for sig in traces metrics logs; do
  n=$(awsc s3api list-objects-v2 --bucket "$BUCKET" --prefix "$sig/$HOUR_PREFIX" \
        --max-items 1 --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo 0)
  if [ "${n:-0}" != "0" ]; then echo "PASS  s3://$BUCKET/$sig/ has objects this hour"
  else echo "FAIL  s3://$BUCKET/$sig/ has no objects this hour (wait a few minutes and re-run)"; FAIL=1; fi
done

echo
[ "$FAIL" = 0 ] && echo "All checks passed." || echo "Some checks failed. See deploy/aws/README.md, Troubleshooting."
exit "$FAIL"
