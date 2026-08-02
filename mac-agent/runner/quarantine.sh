#!/bin/bash
set -Eeuo pipefail

TEST_MODE="${TEST_MODE:-0}"
COMMAND="${1:-status}"
shift || true
CONFIG_PATH="${FACESWAP_QA_CONFIG:-$HOME/.faceswap-qa-agent/config.json}"
ACTIVATION_PATH="${FACESWAP_QA_ACTIVATION_FILE:-$HOME/.faceswap-qa-runner/activation.json}"
APP_ROOT="${FACESWAP_QA_APP_ROOT:-$HOME/.faceswap-qa-agent/app}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REASON="manual"
ACKNOWLEDGEMENT=""

fail() { printf 'runner_quarantine_error=%s\n' "$1" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) [[ $# -ge 2 ]] || fail "missing_reason"; REASON="$2"; shift 2 ;;
    --acknowledge) [[ $# -ge 2 ]] || fail "missing_acknowledgement"; ACKNOWLEDGEMENT="$2"; shift 2 ;;
    *) fail "unsupported_argument:$1" ;;
  esac
done
[[ "$REASON" =~ ^(manual|runner-maintenance|device-maintenance)$ ]] || fail "invalid_reason"

if [[ "$TEST_MODE" == "1" ]]; then
  printf 'mode=test command=%s reason=%s\n' "$COMMAND" "$REASON"
  exit 0
fi
[[ "$(uname -s)" == "Darwin" ]] || fail "macos_required"
[[ "$(id -u)" -ne 0 ]] || fail "root_forbidden"

case "$COMMAND" in
  status)
    PYTHONPATH="$APP_ROOT" "$PYTHON_BIN" -m faceswap_qa_agent.github_host \
      --config "$CONFIG_PATH" --activation "$ACTIVATION_PATH" quarantine-status
    ;;
  set)
    PYTHONPATH="$APP_ROOT" "$PYTHON_BIN" -m faceswap_qa_agent.github_host \
      --config "$CONFIG_PATH" --activation "$ACTIVATION_PATH" quarantine-set \
      --reason "$REASON"
    ;;
  clear)
    PYTHONPATH="$APP_ROOT" "$PYTHON_BIN" -m faceswap_qa_agent.github_host \
      --config "$CONFIG_PATH" --activation "$ACTIVATION_PATH" quarantine-clear \
      --acknowledge "$ACKNOWLEDGEMENT"
    ;;
  *) fail "unsupported_command:$COMMAND" ;;
esac
