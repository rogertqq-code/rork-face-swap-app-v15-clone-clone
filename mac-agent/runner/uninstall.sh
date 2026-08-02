#!/bin/bash
set -Eeuo pipefail

TEST_MODE="${TEST_MODE:-0}"
APPLY=0
PURGE_WORK=0
RUNNER_USER=""
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-faceswap}"
TOKEN_FILE=""
ACTIVATION_DIR="${FACESWAP_QA_RUNNER_HOME:-$HOME/.faceswap-qa-runner}"
ACTIVATION_FILE="$ACTIVATION_DIR/activation.json"

fail() { printf 'runner_uninstall_error=%s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: uninstall.sh --runner-user USER --runner-dir DIR --token-file FILE [--apply] [--purge-work]

Without --apply, no service or GitHub runner mutation occurs. Activation and work
state are retained unless --purge-work is explicitly supplied with --apply.
TEST_MODE=1 suppresses all external service and GitHub calls.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner-user) [[ $# -ge 2 ]] || fail "missing_runner_user"; RUNNER_USER="$2"; shift 2 ;;
    --runner-dir) [[ $# -ge 2 ]] || fail "missing_runner_dir"; RUNNER_DIR="$2"; shift 2 ;;
    --token-file) [[ $# -ge 2 ]] || fail "missing_token_file"; TOKEN_FILE="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --purge-work) PURGE_WORK=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unsupported_argument:$1" ;;
  esac
done

[[ "$RUNNER_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]] || fail "invalid_runner_user"
[[ "$TEST_MODE" == "1" || "$(uname -s)" == "Darwin" ]] || fail "macos_required"
[[ "$(id -u)" -ne 0 ]] || fail "root_forbidden"
[[ "$(id -un)" == "$RUNNER_USER" ]] || fail "dedicated_user_mismatch"
[[ -d "$RUNNER_DIR" && ! -L "$RUNNER_DIR" ]] || fail "runner_directory_missing_or_symlink"
canonical_home="$(cd "$HOME" && pwd -P)"
canonical_runner="$(cd "$RUNNER_DIR" && pwd -P)"
case "$canonical_runner" in "$canonical_home"/*) ;; *) fail "runner_directory_outside_home" ;; esac
[[ -x "$canonical_runner/config.sh" && -x "$canonical_runner/svc.sh" ]] || fail "runner_scripts_missing"
[[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" ]] || fail "token_file_invalid"
if [[ "$(uname -s)" == "Darwin" ]]; then
  token_uid="$(stat -f '%u' "$TOKEN_FILE")"
  mode="$(stat -f '%Lp' "$TOKEN_FILE")"
else
  token_uid="$(stat -c '%u' "$TOKEN_FILE")"
  mode="$(stat -c '%a' "$TOKEN_FILE")"
fi
[[ "$token_uid" == "$(id -u)" ]] || fail "token_file_owner"
[[ "$mode" == "600" ]] || fail "token_file_mode"
IFS= read -r REMOVAL_TOKEN < "$TOKEN_FILE" || fail "token_file_empty"
[[ ${#REMOVAL_TOKEN} -ge 20 && ${#REMOVAL_TOKEN} -le 1024 ]] || fail "token_length"

printf 'runner_user=%s\nrunner_dir=%s\npurge_work=%s\n' "$RUNNER_USER" "$canonical_runner" "$PURGE_WORK"
if [[ "$APPLY" -ne 1 ]]; then
  printf 'mode=dry-run\n'
  exit 0
fi
if [[ "$TEST_MODE" == "1" ]]; then
  if [[ "$PURGE_WORK" -eq 1 ]]; then rm -rf "$canonical_runner/_work"; fi
  rm -f "$ACTIVATION_FILE"
  printf 'mode=test service=skipped unregister=skipped\n'
  exit 0
fi

set +x
(
  cd "$canonical_runner"
  ./svc.sh stop || true
  ./svc.sh uninstall
  if [[ -f .runner ]]; then
    ./config.sh remove --token "$REMOVAL_TOKEN"
  fi
)
rm -f "$ACTIVATION_FILE"
if [[ "$PURGE_WORK" -eq 1 ]]; then
  work_path="$canonical_runner/_work"
  [[ ! -L "$work_path" ]] || fail "work_directory_symlink"
  rm -rf "$work_path"
fi
printf 'mode=applied activation_removed=true work_purged=%s\n' "$PURGE_WORK"
