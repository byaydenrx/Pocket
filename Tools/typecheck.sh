#!/bin/zsh
# Type-checks the app target without building a bundle (fast feedback while editing).
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path)"
swiftc -typecheck -target arm64-apple-macosx14.0 -sdk "$SDK" \
    -I Sources/VMStatisticsCompat -I Sources/HIDEventSystem \
    -j "$(sysctl -n hw.logicalcpu)" Sources/Pocket/**/*.swift 2>&1 \
    | grep -E "error:" | sort -u | head -${1:-80}
