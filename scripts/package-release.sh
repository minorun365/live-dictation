#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${PROJECT_DIR}/dist/文字起こしくん.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Resources/Info.plist")"
ARCHIVE_PATH="${PROJECT_DIR}/dist/live-dictation-v${VERSION}-macos-arm64.zip"

"${PROJECT_DIR}/scripts/build-app.sh"
rm -f "${ARCHIVE_PATH}"
ditto -c -k --keepParent --norsrc "${APP_PATH}" "${ARCHIVE_PATH}"

echo "${ARCHIVE_PATH}"
