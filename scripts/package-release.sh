#!/bin/bash
# Build a reviewable ad-hoc signed universal ZIP; never tags, pushes or uploads.
set -euo pipefail
release_version=${1:-}
release_version=${release_version#v}
if [[ ! $release_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo 'Usage: scripts/package-release.sh MAJOR.MINOR.PATCH' >&2
  exit 2
fi
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
if [[ -n $(git status --porcelain) ]]; then
  echo "Commit or set aside working-tree changes before packaging a release." >&2
  exit 1
fi
release_out=${RELEASE_OUTPUT_DIR:-"$repo_root/dist"}
mkdir -p "$release_out"
release_out=$(cd "$release_out" && pwd)
archive="$release_out/OpenTaskManager-$release_version-universal.zip"
if [[ -e $archive || -e $archive.sha256 ]]; then
  echo "Release output already exists: $archive" >&2
  exit 1
fi
release_build=${RELEASE_BUILD_NUMBER:-$(git rev-list --count HEAD)}
if [[ ! $release_build =~ ^[1-9][0-9]*$ ]]; then
  echo 'RELEASE_BUILD_NUMBER must be a positive integer.' >&2
  exit 2
fi
make generate
xcodebuild -project OpenTaskManager.xcodeproj -scheme OpenTaskManager -configuration Release \
  -derivedDataPath .build/release-package -destination 'generic/platform=macOS' -quiet \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$release_version" \
  CURRENT_PROJECT_VERSION="$release_build" CODE_SIGN_IDENTITY=- build
app=.build/release-package/Build/Products/Release/OpenTaskManager.app
codesign --verify --deep --strict "$app"
archs=$(lipo -archs "$app/Contents/MacOS/OpenTaskManager")
if [[ $archs != *arm64* || $archs != *x86_64* ]]; then
  echo "Universal architectures missing: $archs" >&2
  exit 1
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/otm-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/OpenTaskManager.app"
cp LICENSE "$stage/LICENSE"
cat > "$stage/README.txt" <<EOF
OpenTaskManager $release_version · macOS 14 or later · Intel and Apple Silicon

Move OpenTaskManager.app into Applications. This build is ad-hoc signed,
not Developer ID signed or notarized. macOS may block the first launch;
review System Settings > Privacy & Security if you choose to open it.

Source and release notes:
https://github.com/jtn0123/OpenTaskManager/releases/tag/v$release_version
Build commit: $(git rev-parse HEAD)
GPL-3.0 license: see LICENSE.
EOF
ditto -c -k --sequesterRsrc "$stage" "$archive"
(cd "$release_out" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "Packaged $archive"
