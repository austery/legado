#!/usr/bin/env bash
# Only advance the upstream mirror; never merge upstream into the product branch.
set -euo pipefail

mode="${1:---dry-run}"
if [[ $# -gt 1 || ( "$mode" != '--dry-run' && "$mode" != '--apply' ) ]]; then
  echo 'Usage: sync-upstream-mirror.sh [--dry-run|--apply]' >&2
  exit 2
fi

readonly target_repo='austery/legado'
readonly upstream_repo='huajideshutiao/legado'
readonly target_ref="repos/$target_repo/git/ref/heads/master"
readonly upstream_ref="repos/$upstream_repo/git/ref/heads/master"

fail() {
  echo "::error::$*" >&2
  exit 1
}

metadata="$(gh api "repos/$target_repo" --jq '[.default_branch, .parent.full_name] | @tsv')"
IFS=$'\t' read -r default_branch parent_repo <<< "$metadata"
[[ "$default_branch" == 'native-reader' && "$parent_repo" == "$upstream_repo" ]] ||
  fail 'Expected native-reader as default and huajideshutiao/legado as direct upstream.'

before="$(gh api "$target_ref" --jq '.object.sha')"
upstream="$(gh api "$upstream_ref" --jq '.object.sha')"
[[ "$before" =~ ^[0-9a-f]{40}$ && "$upstream" =~ ^[0-9a-f]{40}$ ]] ||
  fail 'Expected full commit SHAs for both master references.'

echo "Mirror: $before; upstream snapshot: $upstream"
if [[ "$before" == "$upstream" ]]; then
  echo 'master already matches upstream; no update needed.'
  exit 0
fi

comparison="$(gh api "repos/$upstream_repo/compare/$before...$upstream" \
  --jq '[.status, .ahead_by, .behind_by] | @tsv')"
IFS=$'\t' read -r status ahead behind <<< "$comparison"
[[ "$status" == 'ahead' && "$ahead" =~ ^[1-9][0-9]*$ && "$behind" == '0' ]] ||
  fail "Not a pure fast-forward (status=$status, ahead=$ahead, behind=$behind). Review manually; no update made."

if [[ "$mode" == '--dry-run' ]]; then
  echo "Dry run: master can advance by $ahead commits to $upstream."
  exit 0
fi

# force=false also rejects a concurrent non-fast-forward change after comparison.
# GITHUB_TOKEN avoids triggering inherited push workflows that can write commits.
gh api --method PATCH "repos/$target_repo/git/refs/heads/master" \
  -f "sha=$upstream" -F force=false --silent
after="$(gh api "$target_ref" --jq '.object.sha')"
[[ "$after" == "$upstream" ]] || fail "Readback differs from the pinned upstream commit: $after"

message="master fast-forwarded by $ahead commits: $before -> $after"
echo "$message"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' "$message" >> "$GITHUB_STEP_SUMMARY"
fi
