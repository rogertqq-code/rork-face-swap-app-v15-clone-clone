#!/bin/bash
set -Eeuo pipefail

LABEL="com.faceswap.qa-agent"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
INSTALL_ROOT="${FACESWAP_QA_AGENT_HOME:-$HOME/.faceswap-qa-agent}"
APP_ROOT="$INSTALL_ROOT/app"
CONFIG_PATH="$INSTALL_ROOT/config.json"
STATE_ROOT="$INSTALL_ROOT/state"
LOG_ROOT="$INSTALL_ROOT/logs"
ARTIFACT_ROOT="$INSTALL_ROOT/artifacts"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
NODE_VERSION="20.19.5"
APPIUM_VERSION="3.6.0"
XCUITEST_VERSION="12.1.4"
REMOTEXPC_VERSION="5.13.2"
NODE_ROOT="$RUNTIME_ROOT/node-v$NODE_VERSION"
NODE_BIN="$NODE_ROOT/bin/node"
NODE_BIN_DIR="$NODE_ROOT/bin"
APPIUM_ROOT="$RUNTIME_ROOT/appium-$APPIUM_VERSION"
APPIUM_BIN="$APPIUM_ROOT/node_modules/.bin/appium"
APPIUM_HOME="$INSTALL_ROOT/appium-home"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$SOURCE_ROOT/launchd/$LABEL.plist.template"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DOMAIN="gui/$(id -u)"
CONFIG_BACKUP="$CONFIG_PATH.pre-phase9"
PLIST_BACKUP="$PLIST_PATH.pre-phase9"
SWAPPED_APP=0
SWAPPED_NODE=0
SWAPPED_APPIUM=0
SWAPPED_HOME=0
PLIST_WRITTEN=0
SUCCESS=0

cleanup() {
  local status=$?
  rm -rf "$APP_ROOT.new" "$NODE_ROOT.new" "$APPIUM_ROOT.new" "$APPIUM_HOME.new"
  if [[ "$SUCCESS" -ne 1 && "$status" -ne 0 ]]; then
    echo "error: installation failed; restoring the previous deployment" >&2
    launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
    if [[ "$PLIST_WRITTEN" -eq 1 ]]; then
      if [[ -f "$PLIST_BACKUP" ]]; then mv -f "$PLIST_BACKUP" "$PLIST_PATH"; else rm -f "$PLIST_PATH"; fi
    fi
    if [[ -f "$CONFIG_BACKUP" ]]; then mv -f "$CONFIG_BACKUP" "$CONFIG_PATH"; fi
    if [[ "$SWAPPED_HOME" -eq 1 ]]; then
      rm -rf "$APPIUM_HOME"
      [[ ! -e "$APPIUM_HOME.previous" ]] || mv "$APPIUM_HOME.previous" "$APPIUM_HOME"
    fi
    if [[ "$SWAPPED_APPIUM" -eq 1 ]]; then
      rm -rf "$APPIUM_ROOT"
      [[ ! -e "$APPIUM_ROOT.previous" ]] || mv "$APPIUM_ROOT.previous" "$APPIUM_ROOT"
    fi
    if [[ "$SWAPPED_NODE" -eq 1 ]]; then
      rm -rf "$NODE_ROOT"
      [[ ! -e "$NODE_ROOT.previous" ]] || mv "$NODE_ROOT.previous" "$NODE_ROOT"
    fi
    if [[ "$SWAPPED_APP" -eq 1 ]]; then
      rm -rf "$APP_ROOT"
      [[ ! -e "$APP_ROOT.previous" ]] || mv "$APP_ROOT.previous" "$APP_ROOT"
    fi
    if [[ -f "$PLIST_PATH" ]]; then
      launchctl bootstrap "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
      launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    fi
  fi
  return "$status"
}
trap cleanup EXIT

fail() { echo "error: $*" >&2; exit 1; }
escape_sed() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }

if [[ "${FACESWAP_QA_INSTALL_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then fail "this installer must run on macOS"; fi
if [[ -z "$PYTHON_BIN" ]]; then fail "python3 is required"; fi
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  fail "Python 3.11 or newer is required"
fi
for command in xcodebuild xcrun curl tar shasum plutil launchctl; do
  command -v "$command" >/dev/null || fail "$command is required"
done
INSTALL_ROOT="$($PYTHON_BIN -c 'from pathlib import Path; import sys; root=Path(sys.argv[1]).expanduser().resolve(); home=Path.home().resolve(); raise SystemExit(2) if root == home or home not in root.parents else print(root)' "$INSTALL_ROOT")" || fail "FACESWAP_QA_AGENT_HOME must resolve beneath the current user's home directory"
APP_ROOT="$INSTALL_ROOT/app"
CONFIG_PATH="$INSTALL_ROOT/config.json"
STATE_ROOT="$INSTALL_ROOT/state"
LOG_ROOT="$INSTALL_ROOT/logs"
ARTIFACT_ROOT="$INSTALL_ROOT/artifacts"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
NODE_ROOT="$RUNTIME_ROOT/node-v$NODE_VERSION"
NODE_BIN="$NODE_ROOT/bin/node"
NODE_BIN_DIR="$NODE_ROOT/bin"
APPIUM_ROOT="$RUNTIME_ROOT/appium-$APPIUM_VERSION"
APPIUM_BIN="$APPIUM_ROOT/node_modules/.bin/appium"
APPIUM_HOME="$INSTALL_ROOT/appium-home"
CONFIG_BACKUP="$CONFIG_PATH.pre-phase9"
[[ "$INSTALL_ROOT" != *$'\n'* && "$INSTALL_ROOT" != *$'\r'* ]] || fail "installation path contains a line break"

mkdir -p "$INSTALL_ROOT" "$STATE_ROOT" "$LOG_ROOT" "$ARTIFACT_ROOT" "$RUNTIME_ROOT" "$HOME/Library/LaunchAgents"
chmod 700 "$INSTALL_ROOT" "$STATE_ROOT" "$LOG_ROOT" "$ARTIFACT_ROOT" "$RUNTIME_ROOT"

install_node() {
  if [[ -x "$NODE_BIN" ]] && [[ "$($NODE_BIN --version)" == "v$NODE_VERSION" ]]; then return; fi
  local architecture archive directory temporary expected
  case "$(uname -m)" in
    arm64)
      architecture="arm64"
      expected="cfed7503d8d99fbcf2f52e408ec52f616058eb0867b34dbc3437259993ef5cba"
      ;;
    x86_64)
      architecture="x64"
      expected="f9cff058f2766d4d0631dc69b5f7f27664b3a42ff186e25ac7e1ac269af7e696"
      ;;
    *) fail "unsupported macOS architecture: $(uname -m)" ;;
  esac
  directory="node-v$NODE_VERSION-darwin-$architecture"
  archive="$directory.tar.gz"
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/faceswap-node.XXXXXX")"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v$NODE_VERSION/$archive" -o "$temporary/$archive"
  (cd "$temporary" && printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c -)
  tar -xzf "$temporary/$archive" -C "$temporary"
  rm -rf "$NODE_ROOT.new" "$NODE_ROOT.previous"
  mv "$temporary/$directory" "$NODE_ROOT.new"
  if [[ -e "$NODE_ROOT" ]]; then mv "$NODE_ROOT" "$NODE_ROOT.previous"; fi
  mv "$NODE_ROOT.new" "$NODE_ROOT"
  SWAPPED_NODE=1
  rm -rf "$temporary"
  [[ "$($NODE_BIN --version)" == "v$NODE_VERSION" ]] || fail "private Node runtime verification failed"
}

install_node
export PATH="$NODE_BIN_DIR:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
NPM_BIN="$NODE_ROOT/bin/npm"
[[ -x "$NPM_BIN" ]] || fail "private npm runtime is missing"

rm -rf "$APP_ROOT.new"
mkdir -p "$APP_ROOT.new"
cp -R "$SOURCE_ROOT/faceswap_qa_agent" "$SOURCE_ROOT/appium-plugin-faceswap-live" "$APP_ROOT.new/"
cp "$SOURCE_ROOT/pyproject.toml" "$SOURCE_ROOT/README.md" "$SOURCE_ROOT/PHASE9_IMPLEMENTATION_CONTRACT.md" "$APP_ROOT.new/"
rm -rf "$APP_ROOT.previous"
if [[ -e "$APP_ROOT" ]]; then mv "$APP_ROOT" "$APP_ROOT.previous"; fi
mv "$APP_ROOT.new" "$APP_ROOT"
SWAPPED_APP=1

if [[ ! -x "$APPIUM_BIN" ]] || [[ "$($NODE_BIN "$APPIUM_ROOT/node_modules/appium/build/lib/main.js" --version 2>/dev/null || true)" != "$APPIUM_VERSION" ]]; then
  rm -rf "$APPIUM_ROOT.new"
  mkdir -p "$APPIUM_ROOT.new"
  (
    cd "$APPIUM_ROOT.new"
    "$NPM_BIN" init -y >/dev/null
    "$NPM_BIN" install --no-audit --no-fund --save-exact "appium@$APPIUM_VERSION"
  )
  rm -rf "$APPIUM_ROOT.previous"
  if [[ -e "$APPIUM_ROOT" ]]; then mv "$APPIUM_ROOT" "$APPIUM_ROOT.previous"; fi
  mv "$APPIUM_ROOT.new" "$APPIUM_ROOT"
  SWAPPED_APPIUM=1
fi
[[ "$($NODE_BIN "$APPIUM_ROOT/node_modules/appium/build/lib/main.js" --version)" == "$APPIUM_VERSION" ]] || fail "Appium version verification failed"

rm -rf "$APPIUM_HOME.new"
mkdir -m 700 -p "$APPIUM_HOME.new"
(
  export APPIUM_HOME="$APPIUM_HOME.new"
  "$APPIUM_BIN" driver install "appium-xcuitest-driver@$XCUITEST_VERSION" --source=npm --json > "$LOG_ROOT/xcuitest-install.json"
  "$APPIUM_BIN" plugin install "$APP_ROOT/appium-plugin-faceswap-live" --source=local --json > "$LOG_ROOT/faceswap-plugin-install.json"
  cd "$APPIUM_HOME.new"
  "$NPM_BIN" install --save-dev --save-exact --no-audit --no-fund "appium-ios-remotexpc@$REMOTEXPC_VERSION" > "$LOG_ROOT/remotexpc-install.log" 2>&1
  "$APPIUM_BIN" driver list --installed --json > "$LOG_ROOT/appium-drivers.json"
  "$APPIUM_BIN" plugin list --installed --json > "$LOG_ROOT/appium-plugins.json"
)
grep -q "\"version\": \"$XCUITEST_VERSION\"" "$LOG_ROOT/appium-drivers.json" || fail "XCUITest version verification failed"
grep -q '"faceswap-live"' "$LOG_ROOT/appium-plugins.json" || fail "faceswap-live plugin verification failed"
"$NODE_BIN" -e 'const p=require(process.argv[1]); if(p.version!==process.argv[2]) process.exit(1)' \
  "$APPIUM_HOME.new/node_modules/appium-ios-remotexpc/package.json" "$REMOTEXPC_VERSION" || fail "RemoteXPC version verification failed"
rm -rf "$APPIUM_HOME.previous"
if [[ -e "$APPIUM_HOME" ]]; then mv "$APPIUM_HOME" "$APPIUM_HOME.previous"; fi
mv "$APPIUM_HOME.new" "$APPIUM_HOME"
SWAPPED_HOME=1
export APPIUM_HOME
chmod 700 "$APPIUM_HOME"

if [[ -f "$CONFIG_PATH" ]]; then cp -p "$CONFIG_PATH" "$CONFIG_BACKUP"; fi
PYTHONPATH="$APP_ROOT" "$PYTHON_BIN" -m faceswap_qa_agent.install_config \
  --path "$CONFIG_PATH" \
  --repository-root "$REPOSITORY_ROOT" \
  --appium-executable "$APPIUM_BIN" \
  --appium-home "$APPIUM_HOME"
PYTHONPATH="$APP_ROOT" "$PYTHON_BIN" -c 'from faceswap_qa_agent.config import AgentConfig; import sys; AgentConfig.load(sys.argv[1]).ensure_directories()' "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"

TOKEN_PATH="$STATE_ROOT/api-token"
if [[ ! -f "$TOKEN_PATH" ]]; then
  umask 077
  "$PYTHON_BIN" -c 'import secrets,sys; open(sys.argv[1], "x", encoding="utf-8").write(secrets.token_urlsafe(32)+"\n")' "$TOKEN_PATH"
fi
chmod 600 "$TOKEN_PATH"

if ! "$APPIUM_BIN" driver doctor xcuitest --json > "$LOG_ROOT/xcuitest-doctor.json" 2>&1; then
  if [[ "${FACESWAP_QA_SIMULATOR_ONLY:-0}" == "1" ]]; then
    echo "warning: XCUITest doctor reported unmet cable-device prerequisites; simulator-only override is active; see $LOG_ROOT/xcuitest-doctor.json" >&2
  else
    fail "XCUITest doctor reported unmet prerequisites; see $LOG_ROOT/xcuitest-doctor.json (set FACESWAP_QA_SIMULATOR_ONLY=1 only for an explicitly simulator-only host)"
  fi
fi

PYTHON_ESCAPED="$(escape_sed "$PYTHON_BIN")"
CONFIG_ESCAPED="$(escape_sed "$CONFIG_PATH")"
APP_ESCAPED="$(escape_sed "$APP_ROOT")"
STDOUT_ESCAPED="$(escape_sed "$LOG_ROOT/agent.stdout.log")"
STDERR_ESCAPED="$(escape_sed "$LOG_ROOT/agent.stderr.log")"
NODE_BIN_ESCAPED="$(escape_sed "$NODE_BIN_DIR")"
APPIUM_HOME_ESCAPED="$(escape_sed "$APPIUM_HOME")"
if [[ -f "$PLIST_PATH" ]]; then cp -p "$PLIST_PATH" "$PLIST_BACKUP"; fi
sed \
  -e "s|__PYTHON__|$PYTHON_ESCAPED|g" \
  -e "s|__CONFIG__|$CONFIG_ESCAPED|g" \
  -e "s|__WORKDIR__|$APP_ESCAPED|g" \
  -e "s|__STDOUT__|$STDOUT_ESCAPED|g" \
  -e "s|__STDERR__|$STDERR_ESCAPED|g" \
  -e "s|__NODE_BIN__|$NODE_BIN_ESCAPED|g" \
  -e "s|__APPIUM_HOME__|$APPIUM_HOME_ESCAPED|g" \
  "$TEMPLATE" > "$PLIST_PATH.new"
plutil -lint "$PLIST_PATH.new" >/dev/null
chmod 644 "$PLIST_PATH.new"
mv "$PLIST_PATH.new" "$PLIST_PATH"
PLIST_WRITTEN=1

launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
launchctl kickstart -k "$DOMAIN/$LABEL"

for _ in {1..60}; do
  if (cd "$APP_ROOT" && "$PYTHON_BIN" -m faceswap_qa_agent --config "$CONFIG_PATH" health >/dev/null 2>&1); then
    if (cd "$APP_ROOT" && "$PYTHON_BIN" -m faceswap_qa_agent --config "$CONFIG_PATH" appium-start >/dev/null 2>&1); then
      SUCCESS=1
      rm -rf "$APP_ROOT.previous" "$NODE_ROOT.previous" "$APPIUM_ROOT.previous" "$APPIUM_HOME.previous"
      rm -f "$CONFIG_BACKUP" "$PLIST_BACKUP"
      echo "FaceSwap QA agent, Appium, XCUITest, WebDriverAgent integration, and faceswap-live plugin installed and healthy."
      echo "Configuration: $CONFIG_PATH"
      echo "API token: $TOKEN_PATH"
      echo "Appium home: $APPIUM_HOME"
      echo "RemoteXPC: $REMOTEXPC_VERSION"
      echo "XCUITest doctor: $LOG_ROOT/xcuitest-doctor.json"
      echo "Service: $DOMAIN/$LABEL"
      exit 0
    fi
  fi
  sleep 1
done

launchctl print "$DOMAIN/$LABEL" >&2 || true
fail "service or managed Appium did not become healthy; inspect $LOG_ROOT"
