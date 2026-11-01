#!/bin/zsh
# Builds the universal release bundle and packages it for a GitHub release.
# Usage: scripts/package-release.sh
# Output: build/SoundU-<version>.zip and build/SoundU-<version>.zip.sha256
set -euo pipefail
cd "${0:a:h}/.."

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
scripts/build-app.sh --release

zip=build/SoundU-$version.zip
rm -f "$zip" "$zip.sha256"
# ditto keeps the bundle's signature, symlinks and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent build/SoundU.app "$zip"
(cd build && shasum -a 256 "${zip:t}" > "${zip:t}.sha256")

echo "packaged $zip"
cat "$zip.sha256"
