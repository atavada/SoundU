#!/bin/zsh
# Builds build/SoundU.app (universal arm64 + x86_64).
# Usage: scripts/build-app.sh [--release] [--install]
# Signs ad-hoc with the hardened runtime unless SOUNDU_SIGN_IDENTITY is set.
# --install implies --release; it quits a running SoundU and copies the bundle to
# /Applications/SoundU.app, replacing an existing copy only when it is a SoundU bundle
# (launch at login needs /Applications).
set -euo pipefail
cd "${0:a:h}/.."

bundle_id=com.example.SoundU
config=debug
install=0
for arg in "$@"; do
    case "$arg" in
        --release) config=release ;;
        --install) install=1; config=release ;;
        *) echo "usage: $0 [--release] [--install]" >&2; exit 2 ;;
    esac
done
arch=(--arch arm64 --arch x86_64)

swift build -c "$config" $arch
bin="$(swift build -c "$config" $arch --show-bin-path)"

app=build/SoundU.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/SoundU" "$app/Contents/MacOS/SoundU"
cp Resources/Info.plist "$app/Contents/Info.plist"
# App icon and menu-bar template, rendered from the SVG masters in Resources/Icon.
swift scripts/render-icon.swift Resources/Icon build/icon
cp build/icon/AppIcon.icns build/icon/MenuBarTemplate.pdf "$app/Contents/Resources/"
# Everything else in Resources/ (assets) goes into Contents/Resources.
for f in Resources/*(N); do
    [[ "${f:t}" == (Info.plist|Icon) ]] || cp -R "$f" "$app/Contents/Resources/"
done

codesign --force -s "${SOUNDU_SIGN_IDENTITY:--}" --options runtime "$app"
echo "built $app ($config)"

if (( install )); then
    dest=/Applications/SoundU.app
    if [[ -e "$dest" ]]; then
        existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$existing" != "$bundle_id" ]]; then
            echo "refusing to replace $dest: CFBundleIdentifier is '${existing:-missing}', not $bundle_id" >&2
            exit 1
        fi
    fi
    if pgrep -xq SoundU; then
        # Short timeout: a hung app must not block the install forever.
        osascript -e 'with timeout of 5 seconds' -e 'quit app "SoundU"' -e 'end timeout' || true
        for _ in {1..50}; do pgrep -xq SoundU || break; sleep 0.1; done
        if pgrep -xq SoundU; then
            echo "SoundU is still running; quit it and run --install again" >&2
            exit 1
        fi
    fi
    [[ -e "$dest" ]] && rm -rf "$dest"
    ditto "$app" "$dest"
    echo "installed $dest"
fi
