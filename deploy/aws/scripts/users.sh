#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Manage the admin users who can sign in to the admin tools (Cognito user pool).
#   deploy/aws/scripts/users.sh <env-file> list
#   deploy/aws/scripts/users.sh <env-file> add    <email>
#   deploy/aws/scripts/users.sh <env-file> reset  <email>
#   deploy/aws/scripts/users.sh <env-file> remove <email>
#
# add and reset generate a random 24-character password, set it as permanent (no change
# required at first sign-in) and print it once. Emails are login names only: Cognito never
# sends mail to them, so made-up addresses work.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env "${1:-}"
CMD="${2:-list}"
EMAIL="${3:-}"
check_account >&2

POOL=$(stack_output "$APP_STACK" UserPoolId)
[ -n "$POOL" ] || die "stack $APP_STACK has no UserPoolId output. Run deploy.sh first."
DEFAULT_ADMIN=$(stack_output "$APP_STACK" AdminLogin)

gen_password() {
  python3 -c 'import secrets, string
r = secrets.SystemRandom(); a = string.ascii_letters + string.digits
p = [r.choice(string.ascii_uppercase), r.choice(string.ascii_lowercase), r.choice(string.digits)]
p += [r.choice(a) for _ in range(21)]; r.shuffle(p); print("".join(p))'
}
need_email() { [ -n "$EMAIL" ] || die "usage: $(basename "$0") <env-file> $CMD <email>"; }
set_password() {
  awsc cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" \
    --password "$1" --permanent
}
show_login() {
  local domain; domain=$(stack_output "$APP_STACK" DistributionDomain)
  printf '\n  Login:    %s\n  Password: %s\n  Sign in:  https://%s/grafana/\n\n' "$EMAIL" "$1" "$domain"
}

case "$CMD" in
  list)
    awsc cognito-idp list-users --user-pool-id "$POOL" \
      --query 'Users[].{email: Attributes[?Name==`email`].Value | [0], status: UserStatus, enabled: Enabled, created: UserCreateDate}' \
      --output table
    ;;
  add)
    need_email
    PW=$(gen_password)
    awsc cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" \
      --message-action SUPPRESS \
      --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true >/dev/null
    set_password "$PW"
    info "Created $EMAIL. Share the password over a secure channel; it is not stored anywhere."
    show_login "$PW"
    ;;
  reset)
    need_email
    PW=$(gen_password)
    set_password "$PW"
    if [ "$EMAIL" = "$DEFAULT_ADMIN" ]; then
      awsc ssm put-parameter --name "/$ENV_NAME/otel-demo/admin-password" --type SecureString \
        --value "$PW" --overwrite >/dev/null
      info "Reset $EMAIL and updated /$ENV_NAME/otel-demo/admin-password"
    else
      info "Reset $EMAIL. Sessions already signed in stay valid until they expire (12 h)."
    fi
    show_login "$PW"
    ;;
  remove)
    need_email
    [ "$EMAIL" != "$DEFAULT_ADMIN" ] \
      || die "$EMAIL is the default admin and is managed by CloudFormation. Change ADMIN_EMAIL and re-run deploy.sh instead."
    read -r -p "Delete admin user $EMAIL from environment '$ENV_NAME'? Type yes: " answer
    [ "$answer" = "yes" ] || die "not confirmed; nothing deleted"
    awsc cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL"
    info "Deleted $EMAIL. A browser that is already signed in keeps access until its 12 h login expires."
    ;;
  *)
    die "unknown command '$CMD'. Use: list | add <email> | reset <email> | remove <email>"
    ;;
esac
