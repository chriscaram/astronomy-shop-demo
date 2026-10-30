#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Print the admin password for an environment (stored as an SSM SecureString).
#   deploy/aws/scripts/admin-password.sh deploy/aws/envs/dev.env
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"
check_account >&2

awsc ssm get-parameter --name "/$ENV_NAME/otel-demo/admin-password" --with-decryption \
  --query Parameter.Value --output text
