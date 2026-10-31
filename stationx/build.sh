#!/usr/bin/env bash
# Build OUR Chatwoot image from ONE commit on stationx-main and push it under an immutable per-commit tag.
#   stationx/build.sh <commit-sha>
# Builds from a fresh one-commit clone of that commit, so nothing uncommitted can end up in the image. (Not a
# git worktree: the Dockerfile runs "git rev-parse HEAD", and a worktree's .git points outside the build
# context, so the build failed at that step: rehearsal 2026-10-31.)
# Tags ghcr.io/nathanhouse/chatwoot:sha-<12 chars> (refuses if the tag already exists) and prints the digest.
# The deploy (stationx/deploy.sh) deploys by that digest. Procedure: commands/chatwoot/delivery.md (HAL).
#
# CW_PUSH=0 builds into the local Docker instead of pushing (local rehearsal); CW_PLATFORM overrides linux/amd64.
set -euo pipefail

REPO=ghcr.io/nathanhouse/chatwoot
PLATFORM=${CW_PLATFORM:-linux/amd64}   # the server is amd64; the Mac is arm64
PUSH=${CW_PUSH:-1}
CREDS=${CW_GHCR_CREDS:-$HOME/.claude/credentials/github-ghcr.env}

die() { echo "build: $*" >&2; exit 1; }

sha_arg=${1:?usage: stationx/build.sh <commit-sha>}
root=$(git rev-parse --show-toplevel)
git -C "$root" fetch --quiet origin stationx-main
sha=$(git -C "$root" rev-parse --verify "${sha_arg}^{commit}") || die "unknown commit $sha_arg"
# Only commits already on stationx-main ship (delivery-protocol: deploy only from the default branch).
if [[ ${CW_ALLOW_UNMERGED:-0} != 1 ]]; then
  git -C "$root" merge-base --is-ancestor "$sha" FETCH_HEAD || die "$sha is not on origin/stationx-main"
fi
tag="$REPO:sha-${sha:0:12}"

if [[ $PUSH == 1 ]]; then
  # shellcheck disable=SC1090
  source "${CREDS:?}"
  echo "${GITHUB_TOKEN:?}" | docker login ghcr.io -u "${GITHUB_USER:?}" --password-stdin >/dev/null
  # Immutable: a per-commit tag is never rebuilt over.
  if docker buildx imagetools inspect "$tag" >/dev/null 2>&1; then die "$tag already exists; deploy its digest instead"; fi
  output=(--push)
else
  output=(--load)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/cw-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
git init --quiet "$work/src"
git -C "$work/src" fetch --quiet --depth 1 "file://$root" "$sha"
git -C "$work/src" checkout --quiet --detach FETCH_HEAD
[[ $(git -C "$work/src" rev-parse HEAD) == "$sha" ]] || die "clone is not at $sha"

docker buildx build --platform "$PLATFORM" -f "$work/src/docker/Dockerfile" \
  --label org.opencontainers.image.revision="$sha" \
  --label org.opencontainers.image.source=https://github.com/nathanhouse/chatwoot \
  --metadata-file "$work/meta.json" \
  -t "$tag" "${output[@]}" "$work/src"

if [[ $PUSH == 1 ]]; then
  digest=$(docker buildx imagetools inspect "$tag" --format '{{json .Manifest}}' | jq -r .digest)
  echo "built $sha"
  echo "image $REPO@$digest"
else
  echo "built $sha (local, not pushed)"
  echo "image $tag"
fi
