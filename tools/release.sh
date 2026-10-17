#!/bin/sh
# cuts a release: VERSION, a commit, the tag vVERSION, pushed
# usage: tools/release.sh VERSION   (0.14.0; with a dash, 0.14.0-rc1, it is a prerelease)
# prerequisites, all checked below: on main, a clean tree, main in sync with origin/main,
# no tag vVERSION yet. Side effects: writes VERSION, makes one commit and one annotated
# tag, pushes both to origin.
set -eu
cd "$(dirname "$0")/.."
v=${1:-}
die() { echo "release: $*" >&2; exit 1; }
[ -n "$v" ] || die "usage: tools/release.sh VERSION"
echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || die "$v is not a version (MAJOR.MINOR.PATCH)"
[ ${#v} -le 31 ] || die "$v is too long"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not the same as origin/main"
if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then die "v$v exists"; fi
printf '%s\n' "$v" > VERSION
git commit -q -m "Version $v" VERSION
git tag -a "v$v" -m "unn $v"
git push -q origin main "v$v"
echo "pushed v$v; the release workflow builds it: gh run watch"
