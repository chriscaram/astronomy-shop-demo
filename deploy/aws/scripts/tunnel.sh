#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Without arguments after the env file: forward the instance's Envoy port to
# http://localhost:8080 (needs the Session Manager plugin). This reaches every tool,
# including /opamp/, without the Cognito login.
#   deploy/aws/scripts/tunnel.sh deploy/aws/envs/dev.env
# With "shell": open a root shell on the instance instead.
#   deploy/aws/scripts/tunnel.sh deploy/aws/envs/dev.env shell
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"
check_account

command -v session-manager-plugin >/dev/null \
  || die "Session Manager plugin missing. Install: brew install --cask session-manager-plugin"
IID=$(stack_output "$APP_STACK" InstanceId)
[ -n "$IID" ] || die "no InstanceId output on $APP_STACK"

if [ "${2:-}" = "shell" ]; then
  exec "$AWS_CLI" --profile "$AWS_PROFILE" --region "$AWS_REGION" ssm start-session --target "$IID"
fi

LOCAL_PORT="${LOCAL_PORT:-8080}"
info "Forwarding $IID:8080 to http://localhost:$LOCAL_PORT (Ctrl-C to stop)"
exec "$AWS_CLI" --profile "$AWS_PROFILE" --region "$AWS_REGION" ssm start-session --target "$IID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"8080\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
