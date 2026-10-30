#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tear down an environment. Asks you to type the environment name before deleting.
#   deploy/aws/scripts/destroy.sh deploy/aws/envs/dev.env                    app stack only
#   deploy/aws/scripts/destroy.sh deploy/aws/envs/dev.env --include-network  app + network
#   deploy/aws/scripts/destroy.sh deploy/aws/envs/dev.env --cleanup-edge     later: delete the
#                                                         retained Lambda@Edge function
#
# Kept on purpose (DeletionPolicy: Retain):
#   - the S3 telemetry archive bucket (your data)
#   - the Lambda@Edge auth function, because CloudFront edge copies block deletion for
#     up to a few hours after the distribution is gone. Run --cleanup-edge afterwards.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"
MODE="${2:-}"
check_account

EDGE_FN="${ENV_NAME}-otel-admin-auth"

if [ "$MODE" = "--cleanup-edge" ]; then
  if ! awsc lambda get-function --function-name "$EDGE_FN" >/dev/null 2>&1; then
    info "$EDGE_FN does not exist. Nothing to clean up."; exit 0
  fi
  info "Deleting published versions of $EDGE_FN"
  for v in $(awsc lambda list-versions-by-function --function-name "$EDGE_FN" \
               --query 'Versions[?Version!=`$LATEST`].Version' --output text); do
    awsc lambda delete-function --function-name "$EDGE_FN" --qualifier "$v" \
      || die "version $v is still replicated at the edge. Retry in an hour."
  done
  awsc lambda delete-function --function-name "$EDGE_FN"
  info "Deleted $EDGE_FN"
  exit 0
fi

echo "This deletes stack $APP_STACK$([ "$MODE" = --include-network ] && echo " and $NETWORK_STACK")"
echo "in account $EXPECTED_ACCOUNT_ID. The storefront, instance and on-disk telemetry are destroyed."
read -r -p "Type the environment name ($ENV_NAME) to confirm: " answer
[ "$answer" = "$ENV_NAME" ] || die "confirmation did not match; nothing deleted"

BUCKET=$(stack_output "$APP_STACK" TelemetryBucketName)

if stack_exists "$APP_STACK"; then
  info "Deleting $APP_STACK (CloudFront takes 5-15 minutes)"
  awsc cloudformation delete-stack --stack-name "$APP_STACK"
  awsc cloudformation wait stack-delete-complete --stack-name "$APP_STACK"
fi

if [ "$MODE" = "--include-network" ] && stack_exists "$NETWORK_STACK"; then
  info "Deleting $NETWORK_STACK"
  awsc cloudformation delete-stack --stack-name "$NETWORK_STACK"
  awsc cloudformation wait stack-delete-complete --stack-name "$NETWORK_STACK"
fi

cat <<EOF

Done. Left in place on purpose:
  S3 archive:     s3://${BUCKET:-astronomy-shop-$ENV_NAME-$EXPECTED_ACCOUNT_ID}/
                  (to delete it: $AWS_CLI --profile $AWS_PROFILE s3 rb s3://${BUCKET:-<bucket>} --force)
  Edge function:  $EDGE_FN
                  (in a few hours: $0 $1 --cleanup-edge)
Redeploying the same ENV_NAME needs the edge function cleaned up first, and either the
bucket deleted or a different ENV_NAME, because both names are fixed.
EOF
