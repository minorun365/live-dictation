#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/live-dictation-session-logger-test"
MODULE_CACHE="${PROJECT_DIR}/.build/test-module-cache"

mkdir -p "${MODULE_CACHE}"

swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    "${PROJECT_DIR}/Sources/LiveTranslator/SessionRegistry.swift" \
    "${PROJECT_DIR}/Sources/LiveTranslator/SessionLogger.swift" \
    "${PROJECT_DIR}/Sources/LiveTranslator/ScreenshotSessionStore.swift" \
    "${PROJECT_DIR}/Sources/LiveTranslator/SessionHistory.swift" \
    "${PROJECT_DIR}/Sources/LiveTranslator/SpeakerTranscript.swift" \
    "${PROJECT_DIR}/Sources/LiveTranslator/RecentTranscriptWindow.swift" \
    "${PROJECT_DIR}/Tests/SessionLoggerSelfTest.swift" \
    -o "${TEST_BINARY}"

"${TEST_BINARY}"

SCHEDULE_TEST_BINARY="${TMPDIR:-/tmp}/live-dictation-in-person-schedule-test"
swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    "${PROJECT_DIR}/Sources/LiveTranslator/InPersonSchedule.swift" \
    "${PROJECT_DIR}/Tests/InPersonScheduleSelfTest.swift" \
    -o "${SCHEDULE_TEST_BINARY}"

"${SCHEDULE_TEST_BINARY}"

SELECTOR_TEST_BINARY="${TMPDIR:-/tmp}/live-dictation-meeting-window-selector-test"
swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    "${PROJECT_DIR}/Sources/LiveTranslator/MeetingWindowSelector.swift" \
    "${PROJECT_DIR}/Tests/MeetingWindowSelectorSelfTest.swift" \
    -o "${SELECTOR_TEST_BINARY}"

"${SELECTOR_TEST_BINARY}"
