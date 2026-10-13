#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_path="${1:?Usage: scripts/bootstrap_flutter.sh /absolute/path/to/flutter}"
version="$(tr -d '\n\r' < "$project_root/.flutter-version")"
revision="$(tr -d '\n\r' < "$project_root/.flutter-revision")"

if [[ ! -d "$sdk_path/.git" ]]; then
  git clone --depth 1 --branch "$version" https://github.com/flutter/flutter.git "$sdk_path"
fi
if [[ "$(git -C "$sdk_path" rev-parse HEAD)" != "$revision" ]]; then
  echo 'Flutter SDK revision does not match .flutter-revision.' >&2
  exit 1
fi
"$sdk_path/bin/flutter" --version
