#!/bin/bash
set -euo pipefail

LABEL="com.faceswap.qa-agent"
INSTALL_ROOT="${FACESWAP_QA_AGENT_HOME:-$HOME/.faceswap-qa-agent}"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
PURGE=0

if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--purge]" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this uninstaller must run on macOS" >&2
  exit 1
fi

launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

if [[ $PURGE -eq 1 ]]; then
  rm -rf "$INSTALL_ROOT"
  echo "FaceSwap QA agent uninstalled; configuration, database, logs, and artifacts purged."
else
  echo "FaceSwap QA agent uninstalled; state retained at $INSTALL_ROOT."
  echo "Run '$0 --purge' only when permanent deletion is intended."
fi
