# SPDX-License-Identifier: Apache-2.0
# Shared helpers for deploy.sh, verify.sh, admin-password.sh, tunnel.sh and destroy.sh.
# Sourced, not executed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# load_env <env-file>: reads the environment file and sets defaults.
load_env() {
  local file="${1:-}"
  [ -n "$file" ] || die "usage: $(basename "$0") <env-file>   (e.g. deploy/aws/envs/dev.env)"
  [ -f "$file" ] || die "env file not found: $file"
  # shellcheck disable=SC1090
  set -a; . "$file"; set +a

  : "${ENV_NAME:?ENV_NAME is required in $file}"
  : "${AWS_PROFILE:?AWS_PROFILE is required in $file}"
  : "${EXPECTED_ACCOUNT_ID:?EXPECTED_ACCOUNT_ID is required in $file}"
  [[ "$ENV_NAME" =~ ^[a-z][a-z0-9-]{1,14}$ ]] || die "ENV_NAME must match ^[a-z][a-z0-9-]{1,14}\$"

  AWS_REGION="${AWS_REGION:-us-east-1}"
  [ "$AWS_REGION" = "us-east-1" ] || die "AWS_REGION must be us-east-1 (Lambda@Edge functions must live there)"
  AWS_CLI="${AWS_CLI:-aws}"
  command -v "$AWS_CLI" >/dev/null || die "AWS CLI not found ($AWS_CLI). Set AWS_CLI=/path/to/aws in the env file."

  NETWORK_STACK="${ENV_NAME}-otel-network"
  APP_STACK="${ENV_NAME}-otel-demo"
  export AWS_PROFILE AWS_REGION
}

awsc() { "$AWS_CLI" --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

# check_account: refuse to touch an account other than the one the env file names.
check_account() {
  local actual
  actual=$(awsc sts get-caller-identity --query Account --output text) \
    || die "cannot call STS with profile '$AWS_PROFILE'. Log in first (aws sso login --profile $AWS_PROFILE)."
  [ "$actual" = "$EXPECTED_ACCOUNT_ID" ] \
    || die "profile '$AWS_PROFILE' is account $actual, but the env file expects $EXPECTED_ACCOUNT_ID"
  info "Account $actual, region $AWS_REGION, environment '$ENV_NAME'"
}

# stack_output <stack> <key>: prints the output value, or nothing if absent.
stack_output() {
  awsc cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text 2>/dev/null \
    | grep -v '^None$' || true
}

stack_exists() {
  awsc cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}
