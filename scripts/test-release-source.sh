#!/bin/bash
# Regression checks for check-release-source.sh, run in a throwaway repository.
set -euo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-release-source.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/otm-release-source.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
git -c init.defaultBranch=main init -q
git config user.name 'Release source test'
git config user.email 'release-source-test@example.invalid'
git config commit.gpgsign false
git config tag.gpgsign false
git commit -q --allow-empty -m tagged
tagged=$(git rev-parse HEAD)
git tag v1.2.3
git tag -a -m 'Annotated release' v1.2.4
git commit -q --allow-empty -m later
later=$(git rev-parse HEAD)
# A branch named like a missing tag must not stand in for it.
git branch v9.9.9 "$later"

failures=0
expect() {
  local want=$1 what=$2 got=0
  shift 2
  bash "$check" "$@" > /dev/null 2>&1 || got=$?
  if [[ $got -eq $want ]]; then
    echo "ok: $what"
  else
    echo "FAIL: $what (exit $got, expected $want)" >&2
    failures=$((failures + 1))
  fi
}

# Built from a later commit than the tag, as a manual run from main would be.
expect 1 'lightweight tag on an earlier commit is refused' 1.2.3
expect 1 'annotated tag on an earlier commit is refused' 1.2.4
expect 1 'missing tag is refused, though a branch has its name' 9.9.9
expect 1 'remote tag commit that differs from the build is refused' 1.2.3 "$tagged"
expect 1 'empty remote tag commit is refused' 1.2.3 ''
expect 2 'malformed version is rejected' 1.2
expect 2 'missing version is rejected'

git checkout -q --detach refs/tags/v1.2.3
expect 0 'build at the lightweight tag passes' 1.2.3
expect 0 'leading v in the version is accepted' v1.2.3
expect 0 'matching remote tag commit passes' 1.2.3 "$tagged"
expect 1 'remote tag moved after the build is refused' 1.2.3 "$later"
git checkout -q --detach refs/tags/v1.2.4
expect 0 'build at the annotated tag passes' 1.2.4

if [[ $failures -ne 0 ]]; then
  echo "$failures release source check(s) failed" >&2
  exit 1
fi
echo 'All release source checks passed.'
