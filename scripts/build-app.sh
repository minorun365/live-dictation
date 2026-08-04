#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LiveTranslator"
BUILD_DIR="${PROJECT_DIR}/dist"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

cd "${PROJECT_DIR}"
swift build -c release --product "${APP_NAME}"
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

codesign --force --sign - "${APP_DIR}"
echo "${APP_DIR}"
