#!/usr/bin/env bash
# Resolve the base image for an AITER-overlay build and pin it into meta-data.
#
# The overlay is built on top of a published vLLM ROCm nightly:
#   vllm/vllm-openai-rocm:nightly-<vllm-commit>
# resolved here to an immutable commit up front, so a scheduled job is
# reproducible and the resulting tag is traceable to exactly what went into it.
#
# The AITER wheel is not chosen here: which wheel fits depends on the base
# image's ROCm, torch and Python, so build_aiter_overlay.sh picks it from inside
# that image once it has been pulled.
#
# Inputs (all optional; sensible defaults for a nightly scheduled job):
#   VLLM_COMMIT   pin the vLLM nightly commit; otherwise resolve the newest
#                 nightly-<sha> tag on NIGHTLY_REPO from Docker Hub
#   NIGHTLY_REPO  published nightly repo (default vllm/vllm-openai-rocm)
#   OVERLAY_BASE_IMAGE  override the base image entirely (skips the lookup)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NIGHTLY_REPO="${NIGHTLY_REPO:-vllm/vllm-openai-rocm}"
VLLM_COMMIT="${VLLM_COMMIT:-}"
OVERLAY_BASE_IMAGE="${OVERLAY_BASE_IMAGE:-}"

# --- Resolve the vLLM nightly commit -----------------------------------------
if [[ -n "$VLLM_COMMIT" ]]; then
  if [[ ! "$VLLM_COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "^^^ +++"
    echo "VLLM_COMMIT must be a hex sha, got '${VLLM_COMMIT}'." >&2
    exit 1
  fi
  vllm_commit="$(printf '%s' "$VLLM_COMMIT" | tr '[:upper:]' '[:lower:]')"
  echo "--- Using pinned vLLM commit ${vllm_commit}"
else
  echo "--- Resolving newest ${NIGHTLY_REPO}:nightly-<sha> from Docker Hub"
  vllm_commit="$(resolve_latest_nightly_commit "$NIGHTLY_REPO")"
  if [[ -z "$vllm_commit" ]]; then
    echo "^^^ +++"
    echo "Could not find a nightly-<sha> tag on ${NIGHTLY_REPO}." >&2
    echo "Pass VLLM_COMMIT explicitly to bypass the Docker Hub lookup." >&2
    exit 1
  fi
  echo "Resolved nightly commit ${vllm_commit}"
fi
vllm_short="${vllm_commit:0:8}"

if [[ -n "$OVERLAY_BASE_IMAGE" ]]; then
  base_image="$OVERLAY_BASE_IMAGE"
else
  base_image="${NIGHTLY_REPO}:nightly-${vllm_commit}"
fi

buildkite-agent meta-data set "vllm-commit" "$vllm_commit"
buildkite-agent meta-data set "overlay-base-image" "$base_image"

echo "vLLM commit  : ${vllm_commit}"
echo "Base image   : ${base_image}"

vllm_commit_url="https://github.com/vllm-project/vllm/commit/${vllm_commit}"
buildkite-agent annotate --style info --context "aiter-overlay" <<EOF
AITER-overlay build

- Base nightly: \`${base_image}\` (vLLM [\`${vllm_short}\`](${vllm_commit_url}))
EOF
