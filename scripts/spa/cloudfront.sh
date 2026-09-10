#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

normalize_prefix() {
  local value="${1#/}"
  value="${value%/}"
  [[ -n "$value" && "$value" != *"//"* && "$value" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || fail "Unsafe SPA prefix '$1'."
  [[ "/$value/" != *"/../"* && "/$value/" != *"/./"* ]] || fail "Unsafe SPA prefix '$1'."
  printf '%s' "$value"
}

[[ "$#" == 4 ]] || fail "Usage: $0 invalidate COMMENT_PREFIX SPA_PREFIX REGION OUTPUT_JSON"
comment_prefix="$1"
spa_prefix="$(normalize_prefix "$2")"
region="$3"
output_json="$4"
[[ "$comment_prefix" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Unsafe CloudFront comment prefix '$comment_prefix'."

mapfile -t distributions < <(
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?starts_with(Comment, '${comment_prefix}')].Id" \
    --output text --region "$region" --no-cli-pager | tr '\t' '\n' | sed '/^$/d;/^None$/d'
)
(( ${#distributions[@]} > 0 )) || fail "No CloudFront distribution matches comment prefix '$comment_prefix'."

printf '[]\n' > "$output_json"
for distribution in "${distributions[@]}"; do
  invalidation="$(
    aws cloudfront create-invalidation \
      --distribution-id "$distribution" \
      --paths "/${spa_prefix}/*" \
      --query 'Invalidation.Id' --output text --region "$region" --no-cli-pager
  )"
  [[ "$invalidation" != "None" && -n "$invalidation" ]] || fail "CloudFront returned no invalidation ID."
  aws cloudfront wait invalidation-completed \
    --distribution-id "$distribution" \
    --id "$invalidation" \
    --region "$region" --no-cli-pager
  jq --arg distribution "$distribution" --arg invalidation "$invalidation" \
    '. + [{distributionId: $distribution, invalidationId: $invalidation}]' \
    "$output_json" > "${output_json}.next"
  mv "${output_json}.next" "$output_json"
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "invalidations<<EOF"
    cat "$output_json"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
fi
