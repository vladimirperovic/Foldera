#!/bin/bash
# Runs the tests. The Command Line Tools' SwiftPM sometimes forgets to hand
# the compiler the swift-testing macro plugin ("plugin for module
# 'TestingMacros' not found"); passing its folder explicitly avoids that.
set -euo pipefail
cd "$(dirname "$0")"
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
