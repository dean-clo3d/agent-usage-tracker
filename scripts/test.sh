#!/usr/bin/env bash
# Runs the unit tests with Command Line Tools only (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" ]]; then
  for candidate in MacOSX26.5.sdk MacOSX26.sdk MacOSX15.sdk; do
    if [[ -d "$CLT/SDKs/$candidate" ]]; then export SDKROOT="$CLT/SDKs/$candidate"; break; fi
  done
fi

PLUGIN_FLAGS=()
if [[ -d "$CLT/usr/lib/swift/host/plugins/testing" ]]; then
  # CLT ships the swift-testing macro plugin in a subfolder SwiftPM doesn't search.
  PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
fi

swift test --scratch-path "${SCRATCH_PATH:-$HOME/Library/Caches/agent-usage-test}" ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"}
