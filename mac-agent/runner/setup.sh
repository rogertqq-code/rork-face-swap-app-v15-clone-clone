#!/bin/bash
set -Eeuo pipefail

TEST_MODE="${TEST_MODE:-0}"
APPLY=0
REPOSITORY=""
RUNNER_NAME=""
DEVICE_UDID=""
RUNNER_USER=""
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-faceswap}"
TOKEN_FILE=""
ACTIVATION_DIR="${FACESWAP_QA_RUNNER_HOME:-$HOME/.faceswap-qa-runner}"
ACTIVATION_FILE="$ACTIVATION_DIR/activation.json"
REGISTERED=0
SERVICE_INSTALLED=0

fail() { printf 'runner_setup_error=%s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: setup.sh --repository OWNER/REPO --runner-name NAME --device-udid UDID \
  --runner-user USER --runner-dir DIR --token-file FILE [--apply]

Without --apply, validation and the planned configuration are printed only.
The one-time registration token must be provided through a private owned file,
never as a command-line argument. TEST_MODE=1 suppresses all GitHub and service calls.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) [[ $# -ge 2 ]] || fail "missing_repository"; REPOSITORY="$2"; shift 2 ;;
    --runner-name) [[ $# -ge 2 ]] || fail "missing_runner_name"; RUNNER_NAME="$2"; shift 2 ;;
    --device-udid) [[ $# -ge 2 ]] || fail "missing_device_udid"; DEVICE_UDID="$2"; shift 2 ;;
    --runner-user) [[ $# -ge 2 ]] || fail "missing_runner_user"; RUNNER_USER="$2"; shift 2 ;;
    --runner-dir) [[ $# -ge 2 ]] || fail "missing_runner_dir"; RUNNER_DIR="$2"; shift 2 ;;
    --token-file) [[ $# -ge 2 ]] || fail "missing_token_file"; TOKEN_FILE="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unsupported_argument:$1" ;;
  esac
done

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$ ]] || fail "invalid_repository"
[[ "$RUNNER_NAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || fail "invalid_runner_name"
[[ "$DEVICE_UDID" =~ ^[A-Za-z0-9-]{4,128}$ ]] || fail "invalid_device_udid"
[[ "$RUNNER_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]] || fail "invalid_runner_user"
[[ -n "$TOKEN_FILE" ]] || fail "token_file_required"
[[ "$TEST_MODE" == "1" || "$(uname -s)" == "Darwin" ]] || fail "macos_required"
[[ "$(id -u)" -ne 0 ]] || fail "root_forbidden"
[[ "$(id -un)" == "$RUNNER_USER" ]] || fail "dedicated_user_mismatch"

canonical_home="$(cd "$HOME" && pwd -P)"
[[ -d "$RUNNER_DIR" && ! -L "$RUNNER_DIR" ]] || fail "runner_directory_missing_or_symlink"
canonical_runner="$(cd "$RUNNER_DIR" && pwd -P)"
case "$canonical_runner" in
  "$canonical_home"/*) ;;
  *) fail "runner_directory_outside_home" ;;
esac
chmod 700 "$canonical_runner"
[[ -x "$canonical_runner/config.sh" && -x "$canonical_runner/svc.sh" ]] || fail "runner_scripts_missing"
[[ ! -e "$canonical_runner/.runner" ]] || fail "runner_already_configured"

[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" ]] || fail "token_file_invalid"
if [[ "$(uname -s)" == "Darwin" ]]; then
  token_uid="$(stat -f '%u' "$TOKEN_FILE")"
  mode="$(stat -f '%Lp' "$TOKEN_FILE")"
else
  token_uid="$(stat -c '%u' "$TOKEN_FILE")"
  mode="$(stat -c '%a' "$TOKEN_FILE")"
fi
[[ "$token_uid" == "$(id -u)" ]] || fail "token_file_owner"
[[ "$mode" == "600" ]] || fail "token_file_mode"
IFS= read -r REGISTRATION_TOKEN < "$TOKEN_FILE" || fail "token_file_empty"
[[ ${#REGISTRATION_TOKEN} -ge 20 && ${#REGISTRATION_TOKEN} -le 1024 ]] || fail "token_length"
[[ "$REGISTRATION_TOKEN" != *$'\n'* && "$REGISTRATION_TOKEN" != *$'\r'* ]] || fail "token_line_break"

mkdir -p "$ACTIVATION_DIR"
[[ ! -L "$ACTIVATION_DIR" ]] || fail "activation_directory_symlink"
chmod 700 "$ACTIVATION_DIR"

write_activation() {
  local temporary="$ACTIVATION_FILE.tmp.$$"
  umask 077
  printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    '  "activation": "phase11-v1",' \
    "  \"repository\": \"$REPOSITORY\"," \
    '  "environment": "physical-iphone-qa",' \
    "  \"runner_user\": \"$RUNNER_USER\"," \
    "  \"runner_name\": \"$RUNNER_NAME\"," \
    "  \"device_udid\": \"$DEVICE_UDID\"," \
    '  "labels": ["faceswap-cable-qa", "macOS", "self-hosted"]' \
    '}' > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$ACTIVATION_FILE"
}

rollback() {
  local status=$?
  if [[ $status -eq 0 ]]; then return; fi
  set +e
  if [[ "$TEST_MODE" != "1" ]]; then
    if [[ $SERVICE_INSTALLED -eq 1 ]]; then (cd "$canonical_runner" && ./svc.sh stop >/dev/null 2>&1 && ./svc.sh uninstall >/dev/null 2>&1); fi
    if [[ $REGISTERED -eq 1 ]]; then (cd "$canonical_runner" && ./config.sh remove --token "$REGISTRATION_TOKEN" >/dev/null 2>&1); fi
  fi
  rm -f "$ACTIVATION_FILE"
  exit "$status"
}
trap rollback EXIT

printf 'repository=%s\nrunner_name=%s\nrunner_user=%s\ndevice_udid=%s\nrunner_dir=%s\n' \
  "$REPOSITORY" "$RUNNER_NAME" "$RUNNER_USER" "$DEVICE_UDID" "$canonical_runner"
if [[ "$APPLY" -ne 1 ]]; then
  printf 'mode=dry-run\n'
  exit 0
fi

if [[ "$TEST_MODE" == "1" ]]; then
  write_activation
  printf 'mode=test registration=skipped service=skipped activation=%s\n' "$ACTIVATION_FILE"
  exit 0
fi

set +x
(
  cd "$canonical_runner"
  ./config.sh \
    --unattended \
    --url "https://github.com/$REPOSITORY" \
    --token "$REGISTRATION_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "faceswap-cable-qa" \
    --work "_work" \
    --disableupdate
)
REGISTERED=1
write_activation
(
  cd "$canonical_runner"
  ./svc.sh install
  ./svc.sh start
  ./svc.sh status
)
SERVICE_INSTALLED=1
trap - EXIT
printf 'mode=applied activation=%s labels=self-hosted,macOS,faceswap-cable-qa\n' "$ACTIVATION_FILE"
