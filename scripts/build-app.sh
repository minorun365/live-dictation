#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="文字起こしちゃん"
EXECUTABLE_NAME="LiveDictation"
BUNDLE_EXECUTABLE_NAME="文字起こしちゃん"
BUILD_DIR="${PROJECT_DIR}/dist"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

cd "${PROJECT_DIR}"

# SwiftUIのマクロ（@Stateなど）を展開するプラグインは、Command Line Toolsには入っておらず
# Xcodeの中にしかない。xcode-selectがCommand Line Toolsを指していると、ここで
# 「plugin for module 'SwiftUIMacros' not found」でビルドが落ちる。Xcodeが手元にあるなら
# そのプラグインを直接渡して通す。`sudo xcode-select -s /Applications/Xcode.app` を
# 済ませてある環境では、この分岐は空のまま通過する。
BUILD_FLAGS=()
if [ ! -f "$(xcrun --show-sdk-platform-path 2>/dev/null)/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    for candidate in \
        "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"; do
        if [ -f "${candidate}/libSwiftUIMacros.dylib" ]; then
            BUILD_FLAGS=(-Xswiftc -plugin-path -Xswiftc "${candidate}")
            break
        fi
    done
fi

swift build -c release --product "${EXECUTABLE_NAME}" "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${EXECUTABLE_NAME}" "${APP_DIR}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
# メニューバー用アイコン（待機中はアプリと同じ絵の背景を抜いたもの、録音中は別の絵）。
# NSImage(named:) がバンドルの Resources から読むので、@2x / @3x も一緒に入れる。
for name in "MenuBarIcon" "RecordingMenuBarIcon"; do
    for scale in "" "@2x" "@3x"; do
        cp "${PROJECT_DIR}/Resources/${name}${scale}.png" "${APP_DIR}/Contents/Resources/"
    done
done

codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "com.minorun365.LiveDictation"' \
    "${APP_DIR}"
echo "${APP_DIR}"
