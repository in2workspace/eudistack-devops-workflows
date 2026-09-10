#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

[[ "$#" == 3 ]] || fail "Usage: $0 DIRECTORY MANIFEST OUTPUT_TAR_GZ"
directory="$1"
manifest="$2"
output="$3"
[[ -d "$directory" ]] || fail "SPA directory '$directory' does not exist."
[[ -f "$manifest" ]] || fail "Manifest '$manifest' does not exist."
[[ ! -e "$output" ]] || fail "Output '$output' already exists."

node "$(dirname "$0")/manifest.mjs" verify "$directory" "$manifest" > /dev/null
tar --sort=name --format=posix --mtime='UTC 1970-01-01' \
  --pax-option=delete=atime,delete=ctime \
  --owner=0 --group=0 --numeric-owner \
  -C "$directory" -cf - . | gzip -n > "$output"
sha256sum "$output" | awk '{print "sha256:" $1}'
