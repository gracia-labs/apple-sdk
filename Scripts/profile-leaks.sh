#!/usr/bin/env zsh
# Profile mac-viewer (release) under the Leaks instrument. Release binaries lack
# com.apple.security.get-task-allow — which Instruments needs to attach — so we inject it
# after building. Extra args are forwarded to mac-viewer (see `mac-viewer --help`).
set -euo pipefail
cd "${0:a:h}/.."

swift build -c release --product mac-viewer
BIN="$(swift build -c release --product mac-viewer --show-bin-path)/mac-viewer"

codesign -f -s - --entitlements /dev/stdin "$BIN" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST

TRACE="${TMPDIR:-/tmp}/mac-viewer-$(date +%Y%m%d-%H%M%S).trace"
xcrun xctrace record --template Leaks --output "$TRACE" --launch -- "$BIN" "$@"
open "$TRACE"
