#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="funcDictionaryMac"
BUNDLE_ID="com.example.funcDictionary.mac"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${FUNC_DICTIONARY_DERIVED_DATA_DIR:-$ROOT_DIR/.build/macos-derived}"
TEST_DERIVED_DATA_DIR="${FUNC_DICTIONARY_TEST_DERIVED_DATA_DIR:-$ROOT_DIR/.build/macos-tests-derived}"
XCODE_DEVELOPER_DIR="${FUNC_DICTIONARY_XCODE_DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform" ]]; then
  XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_owned_app() {
  local pid command_line
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
      "$APP_BINARY"|"$APP_BINARY "*)
        kill "$pid" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
}

owned_app_is_running() {
  local pid command_line
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
      "$APP_BINARY"|"$APP_BINARY "*) return 0 ;;
    esac
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
  return 1
}

# The Run action may restart the exact app artifact built by this script, but
# tests and verification must never terminate an unrelated or user-launched
# instance with the same process name.  An explicit opt-in is available for
# local debugging when a forceful restart is genuinely wanted.
if [[ "${FUNC_DICTIONARY_FORCE_KILL:-0}" == "1" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
elif [[ "$MODE" == "run" || "$MODE" == "--debug" || "$MODE" == "debug" || "$MODE" == "--logs" || "$MODE" == "logs" || "$MODE" == "--telemetry" || "$MODE" == "telemetry" ]]; then
  stop_owned_app
fi

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
  -project "$ROOT_DIR/funcDictionary.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build

open_app() {
  local app_args=()
  if [[ "${FUNC_DICTIONARY_DEMO_DATA:-0}" == "1" ]]; then
    app_args+=(--demo-data)
  fi
  if [[ "${FUNC_DICTIONARY_UI_TESTING:-0}" == "1" ]]; then
    app_args+=(--ui-testing)
  fi
  if (( ${#app_args[@]} > 0 )); then
    /usr/bin/open -n "$APP_BUNDLE" --args "${app_args[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --test|test)
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
      -project "$ROOT_DIR/funcDictionary.xcodeproj" \
      -scheme "$APP_NAME" \
      -destination 'platform=macOS' \
      -derivedDataPath "$TEST_DERIVED_DATA_DIR" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      ONLY_ACTIVE_ARCH=YES \
      test
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\" OR subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    owned_app_is_running
    ;;
  *)
    echo "usage: $0 [run|--test|--debug|--logs|--telemetry|--verify]" >&2
    echo "set FUNC_DICTIONARY_FORCE_KILL=1 only when an explicit same-name process restart is intended" >&2
    exit 2
    ;;
esac
