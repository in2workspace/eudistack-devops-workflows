#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)/.package-test-work"
rm -rf "$root"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/base/assets"
printf '<html></html>\n' > "$root/base/index.html"
printf 'window.env={url:"${PUBLIC_URL}",secret:"__SECRET_KEY__"};\n' > "$root/base/assets/env.template.js"
printf 'asset\n' > "$root/base/assets/main.abc.js"

scripts="$(cd "$(dirname "$0")" && pwd)"
node "$scripts/manifest.mjs" generate "$root/base" "$root/base-manifest.json" > /dev/null
base_digest="$(jq -r .digest "$root/base-manifest.json")"
bash "$scripts/package-spa.sh" "$root/base" "$root/base-manifest.json" "$root/base-one.tar.gz" > "$root/one.digest"
bash "$scripts/package-spa.sh" "$root/base" "$root/base-manifest.json" "$root/base-two.tar.gz" > "$root/two.digest"
cmp "$root/base-one.tar.gz" "$root/base-two.tar.gz"
cmp "$root/one.digest" "$root/two.digest"

printf '{"PUBLIC_URL":"https://example.test/","SECRET_KEY":"not-logged"}\n' > "$root/config.json"
export GITHUB_OUTPUT="$root/output"
bash "$scripts/materialize-environment.sh" \
  "$root/base-one.tar.gz" "$root/base-manifest.json" "$base_digest" \
  "$root/environment" "$root/config.json" 'PUBLIC_URL,SECRET_KEY' "$root/environment-package"
grep -q '^package_digest=sha256:' "$GITHUB_OUTPUT"
grep -q '^env_digest=sha256:' "$GITHUB_OUTPUT"
node "$scripts/manifest.mjs" verify \
  "$root/environment" "$root/environment-package-manifest.json" > /dev/null

comm -3 \
  <(find "$root/base" -type f -printf '%P\n' | sort) \
  <(find "$root/environment" -type f -printf '%P\n' | sort) \
  | grep -qx $'\tassets/env.js'
echo "package tests passed"
