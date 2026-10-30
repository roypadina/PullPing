#!/bin/bash
# Regenerates the PullPing demo from scratch: compile the app's real code (PullPingCore + the PullPing UI sources, as static modules) + kit +
# scene, render frames offscreen (no window is ever shown, nothing is clicked or captured, no token or keychain is read, the installed app is
# never launched), encode. One command: ./render.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$HERE}"; [ -f "$KIT/DemoKit.swift" ] || KIT="$HERE/../kit"          # repo: kit is vendored next to this file
APP="${APP_SRC:-$HERE/../..}"                                                   # repo: docs/demo -> repo root
GIF="${GIF:-$HERE/../demo.gif}"                                                 # repo: docs/demo.gif
BUILD="${BUILD:-${TMPDIR:-/tmp}/pullping-demo}"                                 # never inside the repo (hundreds of MB of frames)
mkdir -p "$BUILD"
# The app's logic lives in PullPingCore; the UI sources `import PullPingCore`. Both become static modules (UI with -enable-testing, so the
# scene can `@testable import` its internal views, Store and Fixtures). main.swift (the app's entry point) is left out.
swiftc -swift-version 5 -O -emit-library -static -module-name PullPingCore -emit-module -emit-module-path "$BUILD/PullPingCore.swiftmodule" -suppress-warnings \
  -o "$BUILD/libPullPingCore.a" "$APP"/Sources/PullPingCore/*.swift
UI=()
for f in "$APP"/Sources/PullPing/*.swift; do [ "$(basename "$f")" = main.swift ] || UI+=("$f"); done
swiftc -swift-version 5 -O -parse-as-library -enable-testing -emit-library -static -module-name PullPing -emit-module -emit-module-path "$BUILD/PullPing.swiftmodule" \
  -I "$BUILD" -suppress-warnings -o "$BUILD/libPullPing.a" "${UI[@]}"
swiftc -swift-version 5 -parse-as-library -O -suppress-warnings -I "$BUILD" -L "$BUILD" -lPullPing -lPullPingCore -o "$BUILD/demo" \
  "$KIT/DemoKit.swift" "$HERE/scene.swift"
rm -rf "$BUILD/frames"
PULLPING_ASSETS="$APP/Assets/icons" \
  "$BUILD/demo" "$BUILD/frames" 30 -AppleLocale en_US -AppleLanguages "(en)"      # en_US: "2 min. ago", "9:41 AM"-style text
POSTER=${POSTER:-200}  # popover open on the All scope (shows the app, never the empty desktop)
"$KIT/encode.sh" "$BUILD/frames" "$GIF" "${MP4:-}" "${WEBP:-}" "${POSTER:-}"
rm -rf "$BUILD/frames"                                                            # only after a successful encode (set -e)
