#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/dist}"
version="${DAYBOARD_VERSION:-1.5.0}"
build_number="${DAYBOARD_BUILD_NUMBER:-6}"
architecture="${DAYBOARD_ARCH:-$(uname -m)}"
case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac

mkdir -p "$output" "$root/.build/module-cache"
output="$(cd "$output" && pwd)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/dayboard.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Dayboard.app"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -target "$architecture-apple-macosx14.0" \
    -module-cache-path "$root/.build/module-cache" \
    "$root"/Sources/*.swift -o "$app/Contents/MacOS/Dayboard"
cp -X "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp -X "$root/Resources/Dayboard.icns" "$app/Contents/Resources/Dayboard.icns"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

archive="$output/Dayboard-macOS-$architecture.zip"
ditto -c -k --keepParent "$app" "$staging/Dayboard.zip"
mv -f "$staging/Dayboard.zip" "$archive"
printf '%s\n' "$archive"
