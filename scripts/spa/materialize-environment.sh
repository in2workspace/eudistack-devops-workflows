#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

[[ "$#" == 7 ]] || fail "Usage: $0 BASE_ARCHIVE BASE_MANIFEST BASE_DIGEST OUTPUT_DIR CONFIG_JSON REQUIRED_VARIABLES OUTPUT_PREFIX"
archive="$1"
base_manifest="$2"
base_digest="$3"
output_dir="$4"
config_json="$5"
required_variables="$6"
output_prefix="$7"

[[ "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Invalid base digest '$base_digest'."
[[ -f "$archive" && -f "$base_manifest" && -f "$config_json" ]] || fail "A required materialization input is missing."
if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  fail "Base archive contains an unsafe path."
fi
rm -rf "$output_dir"
mkdir -p "$output_dir"
tar -xzf "$archive" -C "$output_dir" --no-same-owner --no-same-permissions
node "$(dirname "$0")/manifest.mjs" verify "$output_dir" "$base_manifest" "$base_digest" > /dev/null
node "$(dirname "$0")/runtime-config.mjs" \
  "$output_dir/assets/env.template.js" \
  "$output_dir/assets/env.js" \
  "$required_variables" \
  "$config_json"
node "$(dirname "$0")/manifest.mjs" generate "$output_dir" "${output_prefix}-manifest.json" > /dev/null
package_digest="$(jq -r .digest "${output_prefix}-manifest.json")"
bash "$(dirname "$0")/package-spa.sh" \
  "$output_dir" "${output_prefix}-manifest.json" "${output_prefix}.tar.gz" > "${output_prefix}-archive-digest.txt"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "package_digest=$package_digest"
    echo "env_digest=$(sha256sum "$output_dir/assets/env.js" | awk '{print "sha256:" $1}')"
    echo "archive_digest=$(cat "${output_prefix}-archive-digest.txt")"
  } >> "$GITHUB_OUTPUT"
fi
