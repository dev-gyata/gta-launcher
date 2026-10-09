#!/usr/bin/env bash
# Prints the CHANGELOG.md section of a version (v1.4.1 or 1.4.1) for its GitHub release; fails if there is none.
# usage: tool/release/release_notes.sh v1.4.1 > notes.md
set -euo pipefail
version="${1#v}"
changelog="$(cd "$(dirname "$0")/../.." && pwd)/CHANGELOG.md"
notes=$(awk -v v="$version" '
  /^## \[/ { p = ($0 ~ "^## \\[" v "\\]"); next }
  /^\[[^]]+\]: / { next }
  p' "$changelog")
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
