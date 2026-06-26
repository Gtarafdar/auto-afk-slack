#!/usr/bin/env bash
#
# Builds AutoAFK as a universal (arm64 + x86_64) macOS .app bundle.
#
# Usage:
#   ./scripts/build_app.sh            # release build, ad-hoc signed
#   CONFIG=debug ./scripts/build_app.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AutoAFK"
DISPLAY_NAME="Auto AFK Slack"
CONFIG="${CONFIG:-release}"
OUTPUT_DIR="dist"
APP_DIR="${OUTPUT_DIR}/${DISPLAY_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building universal binary (arm64 + x86_64), config=${CONFIG}"
swift build -c "${CONFIG}" --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c "${CONFIG}" --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "error: built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

# App icon (transparent) for Finder/Dock.
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi
# Icon used inside the settings popover header.
if [[ -f "Resources/icon_1024.png" ]]; then
  cp "Resources/icon_1024.png" "${RESOURCES_DIR}/icon_1024.png"
fi

echo "==> Verifying architectures"
lipo -info "${MACOS_DIR}/${APP_NAME}" || true

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_DIR}"

# Refresh icon cache so Finder shows the new icon immediately.
touch "${APP_DIR}"

echo ""
echo "Built: ${APP_DIR}"
echo "Run:   open \"${APP_DIR}\""
echo "Show:  open \"${OUTPUT_DIR}\""
echo ""
echo "For distribution, sign with a Developer ID certificate and notarize:"
echo "  codesign --force --options runtime --sign \"Developer ID Application: NAME (TEAMID)\" \"${APP_DIR}\""
echo "  ditto -c -k --keepParent \"${APP_DIR}\" AutoAFK.zip"
echo "  xcrun notarytool submit AutoAFK.zip --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW --wait"
echo "  xcrun stapler staple \"${APP_DIR}\""
