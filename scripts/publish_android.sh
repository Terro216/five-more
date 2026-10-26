#!/usr/bin/env bash
# Push a version tag for the already committed and pushed main revision.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
test "$(git branch --show-current)" = main || { echo 'Switch to main first.' >&2; exit 1; }
test -z "$(git status --porcelain)" || { echo 'Commit the intended changes first.' >&2; exit 1; }
git fetch origin main --tags
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" || {
  echo 'Local main must match origin/main. Review and push it first.' >&2
  exit 1
}
version=$(sed -n 's/^version: \([^+]*\)+.*/\1/p' pubspec.yaml)
tag="v$version"
python3 scripts/release_metadata.py validate --tag "$tag"
if git show-ref --verify --quiet "refs/tags/$tag"; then
  echo 'Tag already exists. Rerun its failed workflow or create a new version.' >&2
  exit 1
fi
git tag -a "$tag" -m "Ещё пять $version"
git push origin "refs/tags/$tag"
printf 'Release build started: https://github.com/Terro216/five-more/actions/workflows/release-android.yml\n'
