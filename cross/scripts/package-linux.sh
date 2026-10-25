#!/bin/bash
# Packages the Linux release build as a .deb (cargo-deb) and an AppImage.
#
# Usage, from anywhere, after `cargo build --release -p opentaskmanager` in cross/:
#   cross/scripts/package-linux.sh [OUTPUT_DIR]
# Needs cargo-deb (cargo install cargo-deb --version 3.8.0 --locked). The
# AppImage tools are downloaded once, each checked against its SHA-256, into
# $OTM_APPIMAGE_TOOLS (a temporary folder by default).
set -euo pipefail

cd "$(dirname "$0")/.."
out=$(realpath -m "${1:-dist}")
version=$(cargo pkgid -p opentaskmanager | sed 's/.*[#@]//')
binary=target/release/opentaskmanager
[[ -x $binary ]] || { echo "No release build at cross/$binary: run cargo build --release -p opentaskmanager" >&2; exit 1; }
mkdir -p "$out"

cargo deb -p opentaskmanager --no-build --output "$out/opentaskmanager_${version}_amd64.deb"

tools=${OTM_APPIMAGE_TOOLS:-${TMPDIR:-/tmp}/otm-appimage-tools}
mkdir -p "$tools"
fetch() {
    local url=$1 sha256=$2 file
    file="$tools/$(basename "$url")"
    [[ -f $file ]] || curl -fsSLo "$file" "$url"
    echo "$sha256  $file" | sha256sum -c --quiet -
}
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
    ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
fetch https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 \
    2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
chmod +x "$tools/appimagetool-x86_64.AppImage"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
appdir=$staging/OpenTaskManager.AppDir
install -Dm755 "$binary" "$appdir/usr/bin/opentaskmanager"
install -Dm644 packaging/linux/opentaskmanager.desktop "$appdir/usr/share/applications/opentaskmanager.desktop"
for size in 32 48 64 128 256 512; do
    install -Dm644 "app/icons/opentaskmanager-$size.png" \
        "$appdir/usr/share/icons/hicolor/${size}x${size}/apps/opentaskmanager.png"
done
ln -s usr/share/applications/opentaskmanager.desktop "$appdir/opentaskmanager.desktop"
ln -s usr/share/icons/hicolor/256x256/apps/opentaskmanager.png "$appdir/opentaskmanager.png"
ln -s usr/bin/opentaskmanager "$appdir/AppRun"
# Extracting rather than mounting, so building needs no FUSE.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$tools/appimagetool-x86_64.AppImage" --no-appstream \
    --runtime-file "$tools/runtime-x86_64" "$appdir" "$out/OpenTaskManager-${version}-x86_64.AppImage"

ls -l "$out"
