#!/usr/bin/env bash
# Builds SuperBucket.app into ./build (release, native arch, ad-hoc signed) for local use.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

swift build -c release "${LINK_FLAGS[@]}" 2>&1 | tail -1
BIN="$(swift build -c release "${LINK_FLAGS[@]}" --show-bin-path)/SuperBucket"

APP="build/SuperBucket.app"
assemble_app "$BIN" "$APP"
sign_app "$APP" "-"
echo "Built $APP"
