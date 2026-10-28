#!/usr/bin/env bash
# Builds Stratus (signed, Debug), installs it to ~/Applications and opens it.
# Usage: scripts/build.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="$HOME/Library/Developer/Stratus/DerivedData"
APP="$HOME/Applications/Stratus.app"

xcodegen generate
xcodebuild -project Stratus.xcodeproj -scheme Stratus -configuration Debug \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build

pkill -x Stratus || true
mkdir -p "$HOME/Applications"
rsync -a --delete "$DERIVED/Build/Products/Debug/Stratus.app/" "$APP/"

if [[ "${1:-}" != "--no-open" ]]; then
  open "$APP"
fi
