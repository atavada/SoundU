#!/bin/zsh
# Builds build/SoundU.app. Usage: scripts/build-app.sh [--release]
# Signs ad-hoc unless SOUNDU_SIGN_IDENTITY is set.
set -euo pipefail
cd "${0:a:h}/.."

config=debug
[[ "${1:-}" == "--release" ]] && config=release

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)"

app=build/SoundU.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/SoundU" "$app/Contents/MacOS/SoundU"
cp Resources/Info.plist "$app/Contents/Info.plist"

codesign --force -s "${SOUNDU_SIGN_IDENTITY:--}" "$app"
echo "built $app ($config)"
