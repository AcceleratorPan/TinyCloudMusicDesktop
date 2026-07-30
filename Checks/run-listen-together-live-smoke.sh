#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

MODE=${1-}
if [[ "$MODE" == "--self-check" ]]; then
  swiftc -parse-as-library -warnings-as-errors Checks/ListenTogetherLiveSmoke.swift \
    -o /tmp/tinycloudmusic-listen-together-redaction-check
  exec /tmp/tinycloudmusic-listen-together-redaction-check
fi

if [[ ${TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES-} != "1" ]]; then
  print "Listen together live smoke skipped: set TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES=1"
  exit 0
fi

CREDENTIAL_DIR="$HOME/Library/Application Support/TinyCloudMusic/ListenTogetherTest"
if [[ ! -s "$CREDENTIAL_DIR/host.cookie" || ! -s "$CREDENTIAL_DIR/member.cookie" ]]; then
  print "Listen together live smoke skipped: local test credentials are missing"
  exit 0
fi

umask 077
COORDINATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tinycloudmusic-listen-together.XXXXXX")
chmod 700 "$COORDINATION_DIR"
HOST_PID=
MEMBER_PID=

cleanup() {
  [[ -n "$HOST_PID" ]] && kill "$HOST_PID" 2>/dev/null || true
  [[ -n "$MEMBER_PID" ]] && kill "$MEMBER_PID" 2>/dev/null || true
  [[ -n "$HOST_PID" ]] && wait "$HOST_PID" 2>/dev/null || true
  [[ -n "$MEMBER_PID" ]] && wait "$MEMBER_PID" 2>/dev/null || true
  if [[ -d "$COORDINATION_DIR" && "$COORDINATION_DIR" == */tinycloudmusic-listen-together.* ]]; then
    rm -rf -- "$COORDINATION_DIR"
  fi
}

interrupt() {
  touch "$COORDINATION_DIR/host-failed" "$COORDINATION_DIR/member-failed"
  chmod 600 "$COORDINATION_DIR/host-failed" "$COORDINATION_DIR/member-failed"
  set +e
  [[ -n "$HOST_PID" ]] && wait "$HOST_PID"
  HOST_PID=
  [[ -n "$MEMBER_PID" ]] && wait "$MEMBER_PID"
  MEMBER_PID=
  set -e
  exit 130
}
trap cleanup EXIT
trap interrupt INT TERM

swift build --build-tests -j 4
BIN_PATH=$(swift build --show-bin-path)
SWIFT_EXECUTABLE=$(xcrun --find swift)
TEST_HELPER="${SWIFT_EXECUTABLE:h:h}/libexec/swift/pm/swiftpm-testing-helper"
TEST_BUNDLE="$BIN_PATH/TinyCloudMusicPackageTests.xctest/Contents/MacOS/TinyCloudMusicPackageTests"
TEST_FRAMEWORK_PATH="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"
if [[ ! -x "$TEST_HELPER" || ! -f "$TEST_BUNDLE" || ! -d "$TEST_FRAMEWORK_PATH" ]]; then
  print "Listen together live smoke failed: Swift test runtime is unavailable"
  exit 1
fi

export TINYCLOUDMUSIC_COOKIE=
export TINYCLOUDMUSIC_MUSIC_U=
export TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE=1

TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE=host \
TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR="$COORDINATION_DIR" \
TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR="$COORDINATION_DIR/nim-host" \
DYLD_FRAMEWORK_PATH="$TEST_FRAMEWORK_PATH" \
"$TEST_HELPER" --test-bundle-path "$TEST_BUNDLE" --skip-build \
  --filter liveRealtimeDelivery "$TEST_BUNDLE" --testing-library swift-testing \
  >"$COORDINATION_DIR/host.log" 2>&1 &
HOST_PID=$!

TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE=member \
TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR="$COORDINATION_DIR" \
TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR="$COORDINATION_DIR/nim-member" \
DYLD_FRAMEWORK_PATH="$TEST_FRAMEWORK_PATH" \
"$TEST_HELPER" --test-bundle-path "$TEST_BUNDLE" --skip-build \
  --filter liveRealtimeDelivery "$TEST_BUNDLE" --testing-library swift-testing \
  >"$COORDINATION_DIR/member.log" 2>&1 &
MEMBER_PID=$!

set +e
wait "$HOST_PID"
HOST_STATUS=$?
HOST_PID=
wait "$MEMBER_PID"
MEMBER_STATUS=$?
MEMBER_PID=
set -e

if (( HOST_STATUS != 0 || MEMBER_STATUS != 0 )); then
  (( HOST_STATUS != 0 )) && print "Listen together Host process failed"
  (( MEMBER_STATUS != 0 )) && print "Listen together Member process failed"
  rg 'Caught error:|member exit notification' \
    "$COORDINATION_DIR/host.log" "$COORDINATION_DIR/member.log" || true
  exit 1
fi

rg 'member exit notification' "$COORDINATION_DIR/host.log" || true
print "Listen together two-process live smoke passed"
