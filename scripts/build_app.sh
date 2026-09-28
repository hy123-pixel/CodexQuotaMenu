#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexQuotaMenu.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/.build-xcode"
APP_DIR="$ROOT_DIR/CodexQuotaMenu.app"

xcodebuild -quiet \
  -project "$PROJECT_PATH" \
  -scheme CodexQuotaMenu \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build \
  CODE_SIGNING_ALLOWED=NO

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/CodexQuotaMenu.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Build output not found: $BUILT_APP" >&2
  exit 1
fi

if [[ -e "$APP_DIR" ]]; then
  find "$APP_DIR" -depth -delete
fi
ditto "$BUILT_APP" "$APP_DIR"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
