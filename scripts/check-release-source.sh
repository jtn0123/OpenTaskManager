#!/bin/bash
# Refuse to attach a build to a release tag that names a different commit.
# With one argument the checkout's own tag vVERSION is read; with a second,
# that commit (the remote tag's, read just before a draft is created) is
# compared instead. Annotated and lightweight tags both resolve to a commit.
set -euo pipefail
release_version=${1:-}
release_version=${release_version#v}
if [[ ! $release_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo 'Usage: scripts/check-release-source.sh MAJOR.MINOR.PATCH [TAG_COMMIT]' >&2
  exit 2
fi
tag="v$release_version"
build_commit=$(git rev-parse --verify 'HEAD^{commit}')
if [[ $# -ge 2 ]]; then
  tag_commit=$2
elif ! tag_commit=$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}"); then
  echo "Tag $tag doesn't exist here. Push the tag first, then run the workflow from it." >&2
  exit 1
fi
if [[ $tag_commit != "$build_commit" ]]; then
  echo "Tag $tag names ${tag_commit:-nothing}, but this build is $build_commit." >&2
  echo 'Run the workflow from the tag, or move the tag deliberately first.' >&2
  exit 1
fi
echo "Tag $tag names the built commit $build_commit."
