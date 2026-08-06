#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="文字起こしちゃん"
EXECUTABLE_NAME="LiveDictation"
BUNDLE_EXECUTABLE_NAME="文字起こしちゃん"
BUILD_DIR="${PROJECT_DIR}/dist"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

cd "${PROJECT_DIR}"
swift build -c release --product "${EXECUTABLE_NAME}"
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${BIN_DIR}/${EXECUTABLE_NAME}" "${APP_DIR}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "com.minorun365.LiveDictation"' \
    "${APP_DIR}"
echo "${APP_DIR}"
