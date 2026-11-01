#!/bin/zsh
# Builds build/SoundU.app (universal arm64 + x86_64). Usage: scripts/build-app.sh [--release]
# Signs ad-hoc with the hardened runtime unless SOUNDU_SIGN_IDENTITY is set.
set -euo pipefail
cd "${0:a:h}/.."

config=debug
[[ "${1:-}" == "--release" ]] && config=release
arch=(--arch arm64 --arch x86_64)

swift build -c "$config" $arch
bin="$(swift build -c "$config" $arch --show-bin-path)"

app=build/SoundU.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/SoundU" "$app/Contents/MacOS/SoundU"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Everything else in Resources/ (icons, assets) goes into Contents/Resources.
for f in Resources/*(N); do
    [[ "${f:t}" == Info.plist ]] || cp -R "$f" "$app/Contents/Resources/"
done

codesign --force -s "${SOUNDU_SIGN_IDENTITY:--}" --options runtime "$app"
echo "built $app ($config)"
