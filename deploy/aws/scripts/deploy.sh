#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Create or update one environment, end to end.
#   deploy/aws/scripts/deploy.sh deploy/aws/envs/dev.env
#
# Steps:
#   1. Checks: AWS account matches the env file, the fork ref exists on the remote.
#   2. Network stack (unless the env file gives an existing VPC).
#   3. App stack, pass 1.
#   4. App stack, pass 2 if the CloudFront domain is new (sets the Cognito callback URL).
#   5. On updates: applies changed instance settings to the running instance.
# Safe to re-run: unchanged stacks are skipped.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"

# ---------- 1. Checks ----------
check_account

# The EC2 instance does not have this checkout: at first boot it downloads the code from
# GitHub. By default it gets the same repository and branch as this checkout, taken from
# the git remote (GIT_REMOTE, default origin) and the current branch. REPO_URL and
# REPO_REF in the env file override that.
REPO_ROOT=$(git -C "$DEPLOY_DIR" rev-parse --show-toplevel 2>/dev/null) \
  || die "$DEPLOY_DIR is not inside a git checkout. Clone the repository instead of copying files."
if [ -z "${REPO_URL:-}" ]; then
  REPO_URL=$(git -C "$REPO_ROOT" remote get-url "${GIT_REMOTE:-origin}" 2>/dev/null) \
    || die "git remote '${GIT_REMOTE:-origin}' not found. Set GIT_REMOTE or REPO_URL in the env file."
fi
case "$REPO_URL" in   # the instance clones anonymously, so use HTTPS
  git@*:*)       _host=${REPO_URL#git@}; REPO_URL="https://${_host%%:*}/${REPO_URL#*:}" ;;
  ssh://git@*)   REPO_URL="https://${REPO_URL#ssh://git@}" ;;
esac
if [ -z "${REPO_REF:-}" ]; then
  REPO_REF=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD \
             || git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null) \
    || die "HEAD is detached and not on a tag. Check out a branch, or set REPO_REF."
fi

info "Instance will clone $REPO_URL at '$REPO_REF'"
# Anonymous lookup (no credential helper), the same way the instance will see the repo.
REMOTE_REFS=$(GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote "$REPO_URL" \
                "refs/heads/$REPO_REF" "refs/tags/$REPO_REF" "refs/tags/$REPO_REF^{}" 2>/dev/null) \
  || die "cannot read $REPO_URL anonymously. The repository must be public."
# Branch wins over a tag of the same name; for an annotated tag use the commit (^{}).
REMOTE_SHA=$(printf '%s\n' "$REMOTE_REFS" | awk '$2 ~ /^refs\/heads\//{h=$1} $2 ~ /\^\{\}$/{p=$1} $2 ~ /^refs\/tags\//{t=$1} END{print h ? h : (p ? p : t)}')
[ -n "$REMOTE_SHA" ] || die "'$REPO_REF' is not on $REPO_URL yet. Push it first: git push ${GIT_REMOTE:-origin} $REPO_REF"
LOCAL_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  if [ "${ALLOW_UNPUSHED:-false}" = "true" ]; then
    warn "local HEAD ($LOCAL_SHA) differs from '$REPO_REF' on GitHub ($REMOTE_SHA); continuing because ALLOW_UNPUSHED=true"
  else
    die "local HEAD ($LOCAL_SHA) differs from '$REPO_REF' on GitHub ($REMOTE_SHA). The instance would get the GitHub version. Push (or pull) first, or set ALLOW_UNPUSHED=true."
  fi
fi
if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- deploy/aws)" ]; then
  warn "deploy/aws has uncommitted changes. The instance only sees what is pushed."
fi

TAGS=(Project=otel-demo "Environment=$ENV_NAME")

# ---------- 2. Network ----------
if [ -n "${VPC_ID:-}" ]; then
  info "Using existing VPC $VPC_ID"
  : "${PRIVATE_SUBNET_A:?PRIVATE_SUBNET_A is required when VPC_ID is set}"
  : "${PRIVATE_SUBNET_B:?PRIVATE_SUBNET_B is required when VPC_ID is set}"
else
  info "Deploying network stack $NETWORK_STACK"
  awsc cloudformation deploy --stack-name "$NETWORK_STACK" \
    --template-file "$DEPLOY_DIR/templates/network.yaml" \
    --parameter-overrides "EnvName=$ENV_NAME" "VpcCidr=${VPC_CIDR:-10.20.0.0/16}" \
    --tags "${TAGS[@]}" --no-fail-on-empty-changeset
  VPC_ID=$(stack_output "$NETWORK_STACK" VpcId)
  PRIVATE_SUBNET_A=$(stack_output "$NETWORK_STACK" PrivateSubnetA)
  PRIVATE_SUBNET_B=$(stack_output "$NETWORK_STACK" PrivateSubnetB)
fi

PREFIX_LIST=$(awsc ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)
[ -n "$PREFIX_LIST" ] && [ "$PREFIX_LIST" != "None" ] || die "CloudFront origin-facing prefix list not found"

# ---------- 3./4. App stack ----------
# Pin the AMI: resolve the latest AL2023 arm64 image on the first deploy and reuse it on
# updates. A different AMI ID replaces the instance and deletes the on-disk telemetry.
# Set AMI_ID in the env file to move to a newer image on purpose.
CURRENT_DOMAIN=""; CURRENT_CONFIG=""; EXISTING=false
if stack_exists "$APP_STACK"; then
  EXISTING=true
  CURRENT_DOMAIN=$(stack_output "$APP_STACK" DistributionDomain)
  CURRENT_CONFIG=$(awsc ssm get-parameter --name "/$ENV_NAME/otel-demo/config" \
                     --query Parameter.Value --output text 2>/dev/null || true)
  [ -n "${AMI_ID:-}" ] || AMI_ID=$(awsc cloudformation describe-stacks --stack-name "$APP_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='AmiId'].ParameterValue | [0]" --output text)
fi
[ -n "${AMI_ID:-}" ] || AMI_ID=$(awsc ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text)
info "AMI $AMI_ID"

deploy_app() {
  local public_domain="$1"
  info "Deploying app stack $APP_STACK (PublicDomain='${public_domain}')"
  awsc cloudformation deploy --stack-name "$APP_STACK" \
    --template-file "$DEPLOY_DIR/templates/otel-demo.yaml" \
    --capabilities CAPABILITY_IAM \
    --tags "${TAGS[@]}" --no-fail-on-empty-changeset \
    --parameter-overrides \
      "EnvName=$ENV_NAME" \
      "RepoUrl=$REPO_URL" \
      "RepoRef=$REPO_REF" \
      "DemoVersion=${DEMO_VERSION:-3.1.0}" \
      "InstanceType=${INSTANCE_TYPE:-t4g.large}" \
      "AmiId=$AMI_ID" \
      "RootVolumeGiB=${ROOT_VOLUME_GIB:-150}" \
      "LocalRetentionDays=${LOCAL_RETENTION_DAYS:-60}" \
      "S3RetentionDays=${S3_RETENTION_DAYS:-90}" \
      "AdminEmail=${ADMIN_EMAIL:-admin@example.com}" \
      "VpcId=$VPC_ID" \
      "PrivateSubnetA=$PRIVATE_SUBNET_A" \
      "PrivateSubnetB=$PRIVATE_SUBNET_B" \
      "CloudFrontPrefixList=$PREFIX_LIST" \
      "PublicDomain=$public_domain"
}

deploy_app "$CURRENT_DOMAIN"

DOMAIN=$(stack_output "$APP_STACK" DistributionDomain)
if [ "$(stack_output "$APP_STACK" PublicDomainParameter)" != "$DOMAIN" ]; then
  info "Second pass: pointing the Cognito callback at $DOMAIN"
  deploy_app "$DOMAIN"
fi

# EC2 does not re-run UserData, so push changed settings to the running instance.
NEW_CONFIG=$(awsc ssm get-parameter --name "/$ENV_NAME/otel-demo/config" --query Parameter.Value --output text)
if $EXISTING && [ "$NEW_CONFIG" != "$CURRENT_CONFIG" ]; then
  info "Instance settings changed; applying them to the running instance"
  "$SCRIPT_DIR/apply-config.sh" "$1"
elif $EXISTING; then
  info "Instance settings unchanged. After pushing new deploy/aws/config files, run apply-config.sh."
fi

# ---------- Summary ----------
cat <<EOF

Deployed environment '$ENV_NAME'.
  Store:        https://$DOMAIN/
  Admin tools:  https://$DOMAIN/grafana/  /jaeger/ui/  /feature/  /loadgen/  /telemetry/
  Admin login:  ${ADMIN_EMAIL:-admin@example.com}
  Password:     deploy/aws/scripts/admin-password.sh $1
  Instance:     $(stack_output "$APP_STACK" InstanceId)
  S3 archive:   s3://$(stack_output "$APP_STACK" TelemetryBucketName)/

$($EXISTING && echo "The instance keeps running; give it a minute if settings were applied." \
             || echo "The instance needs 5-10 more minutes to pull images and start.")
Then check everything with:
  deploy/aws/scripts/verify.sh $1
EOF
