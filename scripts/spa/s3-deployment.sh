#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

require_output() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || fail "GITHUB_OUTPUT is not configured."
}

normalize_prefix() {
  local value="${1#/}"
  value="${value%/}"
  [[ -n "$value" && "$value" != *"//"* && "$value" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || fail "Unsafe S3 prefix '$1'."
  [[ "/$value/" != *"/../"* && "/$value/" != *"/./"* ]] || fail "Unsafe S3 prefix '$1'."
  printf '%s' "$value"
}

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Invalid SHA-256 digest '$1'."
}

state_prefix_for() {
  local live="$1"
  printf '.eudistack-spa-state/%s' "$(printf '%s' "$live" | sha256sum | awk '{print $1}')"
}

download_prefix() {
  local bucket="$1" prefix="$2" destination="$3"
  rm -rf "$destination"
  mkdir -p "$destination"
  aws s3 sync "s3://${bucket}/${prefix}/" "$destination/" --delete --only-show-errors
  rm -f "$destination/.eudistack-manifest.json"
}

upload_content() {
  local bucket="$1" prefix="$2" directory="$3"
  aws s3 sync "$directory/" "s3://${bucket}/${prefix}/" \
    --delete --exclude 'index.html' --exclude 'ngsw.json' --exclude 'assets/env.js' \
    --cache-control 'public,max-age=31536000,immutable' --only-show-errors
  for entry in assets/env.js ngsw.json index.html; do
    if [[ -f "$directory/$entry" ]]; then
      aws s3 cp "$directory/$entry" "s3://${bucket}/${prefix}/${entry}" \
        --cache-control 'no-store,max-age=0' --content-type "$(
          case "$entry" in
            *.html) echo 'text/html; charset=utf-8' ;;
            *.json) echo 'application/json; charset=utf-8' ;;
            *.js) echo 'text/javascript; charset=utf-8' ;;
          esac
        )" --only-show-errors
    fi
  done
}

inspect() {
  local bucket="$1" live state work
  live="$(normalize_prefix "$2")"
  work="$3"
  state="$(state_prefix_for "$live")"
  require_output
  mkdir -p "$work"

  if aws s3 cp "s3://${bucket}/${state}/current.json" "$work/current.json" --only-show-errors 2>/dev/null; then
    jq -e '
      .schemaVersion == 1
      and (.version | type == "string")
      and (.prefix | type == "string" and length > 0)
      and (.packageDigest | test("^sha256:[0-9a-f]{64}$"))
    ' "$work/current.json" > /dev/null || fail "Stored deployment state is invalid."
    prefix="$(jq -r .prefix "$work/current.json")"
    version="$(jq -r .version "$work/current.json")"
    package_digest="$(jq -r .packageDigest "$work/current.json")"
    base_digest="$(jq -r '.baseArtifactDigest // .packageDigest' "$work/current.json")"
    legacy=false
  else
    legacy_dir="$work/legacy"
    download_prefix "$bucket" "$live" "$legacy_dir"
    node "$(dirname "$0")/manifest.mjs" generate "$legacy_dir" "$work/legacy-manifest.json" > /dev/null
    package_digest="$(jq -r .digest "$work/legacy-manifest.json")"
    prefix="${state}/legacy/${package_digest#sha256:}"
    upload_content "$bucket" "$prefix" "$legacy_dir"
    aws s3 cp "$work/legacy-manifest.json" "s3://${bucket}/${prefix}/.eudistack-manifest.json" \
      --cache-control 'no-store,max-age=0' --content-type application/json --only-show-errors
    version="0.0.0"
    base_digest="$package_digest"
    legacy=true
  fi
  {
    echo "version=$version"
    echo "prefix=$prefix"
    echo "package_digest=$package_digest"
    echo "base_artifact_digest=$base_digest"
    echo "legacy_bootstrap=$legacy"
  } >> "$GITHUB_OUTPUT"
}

publish() {
  local bucket="$1" prefix directory manifest digest existing object_count verify_dir
  prefix="$(normalize_prefix "$2")"
  directory="$3"
  manifest="$4"
  digest="$5"
  validate_digest "$digest"
  node "$(dirname "$0")/manifest.mjs" verify "$directory" "$manifest" "$digest" > /dev/null
  if existing="$(aws s3 cp "s3://${bucket}/${prefix}/.eudistack-manifest.json" - --only-show-errors 2>/dev/null)"; then
    [[ "$(jq -r .digest <<< "$existing")" == "$digest" ]] \
      || fail "Immutable prefix s3://${bucket}/${prefix}/ already contains different content."
    verify_dir="${GITHUB_WORKSPACE:-.}/.spa-existing-${GITHUB_RUN_ID:-local}"
    download_prefix "$bucket" "$prefix" "$verify_dir"
    node "$(dirname "$0")/manifest.mjs" verify "$verify_dir" "$manifest" "$digest" > /dev/null
    rm -rf "$verify_dir"
    echo "Immutable prefix already contains the requested package."
    return
  fi
  object_count="$(
    aws s3api list-objects-v2 \
      --bucket "$bucket" --prefix "${prefix}/" --max-items 1 \
      --query 'Contents[0].Key' --output text --no-cli-pager
  )"
  [[ -z "$object_count" || "$object_count" == "None" ]] \
    || fail "Immutable prefix s3://${bucket}/${prefix}/ contains objects but no valid manifest."
  upload_content "$bucket" "$prefix" "$directory"
  aws s3 cp "$manifest" "s3://${bucket}/${prefix}/.eudistack-manifest.json" \
    --cache-control 'no-store,max-age=0' --content-type application/json --only-show-errors
}

activate() {
  local bucket="$1" source live
  source="$(normalize_prefix "$2")"
  live="$(normalize_prefix "$3")"
  [[ "$source" != "$live" ]] || fail "Immutable and live prefixes must differ."
  aws s3 sync "s3://${bucket}/${source}/" "s3://${bucket}/${live}/" \
    --delete --exclude '.eudistack-manifest.json' \
    --exclude 'index.html' --exclude 'ngsw.json' --exclude 'assets/env.js' \
    --only-show-errors
  if aws s3api head-object --bucket "$bucket" --key "${live}/.eudistack-manifest.json" > /dev/null 2>&1; then
    aws s3 rm "s3://${bucket}/${live}/.eudistack-manifest.json" --only-show-errors
  fi
  for entry in assets/env.js ngsw.json index.html; do
    if aws s3api head-object --bucket "$bucket" --key "${source}/${entry}" > /dev/null 2>&1; then
      aws s3 cp "s3://${bucket}/${source}/${entry}" "s3://${bucket}/${live}/${entry}" \
        --metadata-directive COPY --only-show-errors
    else
      if aws s3api head-object --bucket "$bucket" --key "${live}/${entry}" > /dev/null 2>&1; then
        aws s3 rm "s3://${bucket}/${live}/${entry}" --only-show-errors
      fi
    fi
  done
}

verify() {
  local bucket="$1" live manifest digest work
  live="$(normalize_prefix "$2")"
  manifest="$3"
  digest="$4"
  work="$5"
  validate_digest "$digest"
  download_prefix "$bucket" "$live" "$work"
  node "$(dirname "$0")/manifest.mjs" verify "$work" "$manifest" "$digest"
}

verify_release_live() {
  local bucket="$1" source="$2" live="$3" digest="$4" work="$5" manifest
  source="$(normalize_prefix "$source")"
  live="$(normalize_prefix "$live")"
  manifest="${work}-manifest.json"
  aws s3 cp "s3://${bucket}/${source}/.eudistack-manifest.json" "$manifest" --only-show-errors
  verify "$bucket" "$live" "$manifest" "$digest" "$work"
  rm -f "$manifest"
}

finalize() {
  local bucket="$1" live="$2" previous_prefix="$3" previous_version="$4"
  local previous_digest="$5" new_prefix="$6" new_version="$7" new_digest="$8" source_sha="$9"
  local base_digest="${10}" env_digest="${11}" state current_file previous_file
  live="$(normalize_prefix "$live")"
  previous_prefix="$(normalize_prefix "$previous_prefix")"
  new_prefix="$(normalize_prefix "$new_prefix")"
  validate_digest "$previous_digest"
  validate_digest "$new_digest"
  validate_digest "$base_digest"
  validate_digest "$env_digest"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid source SHA '$source_sha'."
  state="$(state_prefix_for "$live")"
  current_file="${RUNNER_TEMP:-.}/spa-current-${GITHUB_RUN_ID:-local}.json"
  previous_file="${RUNNER_TEMP:-.}/spa-previous-${GITHUB_RUN_ID:-local}.json"
  jq -n --arg version "$previous_version" --arg prefix "$previous_prefix" --arg packageDigest "$previous_digest" \
    '{schemaVersion:1,version:$version,prefix:$prefix,packageDigest:$packageDigest}' > "$previous_file"
  jq -n --arg version "$new_version" --arg prefix "$new_prefix" --arg packageDigest "$new_digest" \
    --arg sourceSha "$source_sha" --arg baseArtifactDigest "$base_digest" --arg envJsDigest "$env_digest" \
    '{schemaVersion:1,version:$version,prefix:$prefix,packageDigest:$packageDigest,sourceSha:$sourceSha,baseArtifactDigest:$baseArtifactDigest,envJsDigest:$envJsDigest}' > "$current_file"
  aws s3 cp "$previous_file" "s3://${bucket}/${state}/previous.json" \
    --cache-control 'no-store,max-age=0' --content-type application/json --only-show-errors
  aws s3 cp "$current_file" "s3://${bucket}/${state}/current.json" \
    --cache-control 'no-store,max-age=0' --content-type application/json --only-show-errors
  rm -f "$current_file" "$previous_file"
}

case "${1:-}" in
  inspect)
    [[ "$#" == 4 ]] || fail "Usage: $0 inspect BUCKET LIVE_PREFIX WORK_DIRECTORY"
    inspect "$2" "$3" "$4"
    ;;
  publish)
    [[ "$#" == 6 ]] || fail "Usage: $0 publish BUCKET RELEASE_PREFIX DIRECTORY MANIFEST DIGEST"
    publish "$2" "$3" "$4" "$5" "$6"
    ;;
  activate|rollback)
    [[ "$#" == 4 ]] || fail "Usage: $0 ${1} BUCKET SOURCE_PREFIX LIVE_PREFIX"
    activate "$2" "$3" "$4"
    ;;
  verify)
    [[ "$#" == 6 ]] || fail "Usage: $0 verify BUCKET LIVE_PREFIX MANIFEST DIGEST WORK_DIRECTORY"
    verify "$2" "$3" "$4" "$5" "$6"
    ;;
  verify-release-live)
    [[ "$#" == 6 ]] || fail "Usage: $0 verify-release-live BUCKET RELEASE_PREFIX LIVE_PREFIX DIGEST WORK_DIRECTORY"
    verify_release_live "$2" "$3" "$4" "$5" "$6"
    ;;
  finalize)
    [[ "$#" == 12 ]] || fail "Usage: $0 finalize BUCKET LIVE_PREFIX PREVIOUS_PREFIX PREVIOUS_VERSION PREVIOUS_DIGEST NEW_PREFIX NEW_VERSION NEW_DIGEST SOURCE_SHA BASE_DIGEST ENV_DIGEST"
    finalize "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
    ;;
  *)
    fail "Usage: $0 {inspect|publish|activate|verify|verify-release-live|rollback|finalize} ..."
    ;;
esac
