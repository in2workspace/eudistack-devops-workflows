#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)/.s3-test-work"
rm -rf "$root"
mkdir -p "$root"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/s3/test-bucket/wallet" "$root/work"
printf 'legacy\n' > "$root/s3/test-bucket/wallet/index.html"

cat > "$root/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
root="${MOCK_S3_ROOT:?}"
if [[ "$1 $2" == "s3 sync" ]]; then
  source="$3"; destination="$4"
  copy_dir() {
    local from="$1" to="$2"
    mkdir -p "$to"
    cp -R "$from/." "$to/"
  }
  if [[ "$source" == s3://* && "$destination" == s3://* ]]; then
    from="${source#s3://}"; to="${destination#s3://}"
    rm -rf "$root/${to%/}"; copy_dir "$root/${from%/}" "$root/${to%/}"
  elif [[ "$source" == s3://* ]]; then
    value="${source#s3://}"; copy_dir "$root/${value%/}" "${destination%/}"
  elif [[ "$destination" == s3://* ]]; then
    value="${destination#s3://}"; rm -rf "$root/${value%/}"; copy_dir "${source%/}" "$root/${value%/}"
  fi
elif [[ "$1 $2" == "s3 cp" ]]; then
  source="$3"; destination="$4"
  if [[ "$source" == s3://* && "$destination" == s3://* ]]; then
    target="$root/${destination#s3://}"; mkdir -p "$(dirname "$target")"; cp "$root/${source#s3://}" "$target"
  elif [[ "$source" == s3://* && "$destination" == "-" ]]; then
    cat "$root/${source#s3://}"
  elif [[ "$source" == s3://* ]]; then
    mkdir -p "$(dirname "$destination")"; cp "$root/${source#s3://}" "$destination"
  elif [[ "$destination" == s3://* ]]; then
    target="$root/${destination#s3://}"; mkdir -p "$(dirname "$target")"; cp "$source" "$target"
  fi
elif [[ "$1 $2" == "s3api head-object" ]]; then
  bucket="$4"; key="$6"
  [[ -f "$root/$bucket/$key" ]]
elif [[ "$1 $2" == "s3api list-objects-v2" ]]; then
  bucket="$4"; prefix="$6"
  if find "$root/$bucket/$prefix" -type f -print -quit 2>/dev/null | grep -q .; then
    echo "$prefix/existing"
  else
    echo None
  fi
elif [[ "$1 $2" == "s3 rm" ]]; then
  rm -f "$root/${3#s3://}"
else
  echo "unsupported mock aws command: $*" >&2
  exit 2
fi
MOCK
chmod +x "$root/bin/aws"

export PATH="$root/bin:$PATH"
export MOCK_S3_ROOT="$root/s3"
export GITHUB_OUTPUT="$root/output"
export RUNNER_TEMP="$root"
# Keep Git Bash on Windows from rewriting mocked s3:// arguments as local paths.
export MSYS2_ARG_CONV_EXCL='s3://'
script="$(cd "$(dirname "$0")" && pwd)/s3-deployment.sh"

bash "$script" inspect test-bucket wallet "$root/work"
grep -q '^version=0.0.0$' "$GITHUB_OUTPUT"
grep -q '^legacy_bootstrap=true$' "$GITHUB_OUTPUT"
previous_prefix="$(awk -F= '/^prefix=/{print $2}' "$GITHUB_OUTPUT")"
previous_digest="$(awk -F= '/^package_digest=/{print $2}' "$GITHUB_OUTPUT")"
[[ -f "$root/s3/test-bucket/$previous_prefix/index.html" ]]

mkdir -p "$root/new/assets"
printf 'new\n' > "$root/new/index.html"
printf 'runtime\n' > "$root/new/assets/env.js"
node "$(dirname "$script")/manifest.mjs" generate "$root/new" "$root/new-manifest.json" > /dev/null
digest="$(jq -r .digest "$root/new-manifest.json")"
bash "$script" publish test-bucket releases/1.0.0 "$root/new" "$root/new-manifest.json" "$digest"
printf 'different\n' > "$root/new/index.html"
node "$(dirname "$script")/manifest.mjs" generate "$root/new" "$root/different-manifest.json" > /dev/null
different_digest="$(jq -r .digest "$root/different-manifest.json")"
if bash "$script" publish test-bucket releases/1.0.0 "$root/new" "$root/different-manifest.json" "$different_digest" 2>/dev/null; then
  echo "immutable collision was not rejected" >&2
  exit 1
fi
printf 'new\n' > "$root/new/index.html"
bash "$script" activate test-bucket releases/1.0.0 wallet
grep -q new "$root/s3/test-bucket/wallet/index.html" || {
  find "$root/s3/test-bucket" -type f -print
  cat "$root/s3/test-bucket/wallet/index.html"
  exit 1
}
bash "$script" finalize test-bucket wallet \
  "$previous_prefix" 0.0.0 "$previous_digest" \
  releases/1.0.0 1.0.0 "$digest" \
  0123456789abcdef0123456789abcdef01234567 "$digest" "$digest"
: > "$GITHUB_OUTPUT"
bash "$script" inspect test-bucket wallet "$root/work-current"
grep -q '^version=1.0.0$' "$GITHUB_OUTPUT"
grep -q "^base_artifact_digest=$digest$" "$GITHUB_OUTPUT"
bash "$script" rollback test-bucket "$previous_prefix" wallet
grep -q legacy "$root/s3/test-bucket/wallet/index.html"
bash "$script" verify-release-live test-bucket "$previous_prefix" wallet "$previous_digest" "$root/rollback-check"
echo "s3 deployment tests passed"
