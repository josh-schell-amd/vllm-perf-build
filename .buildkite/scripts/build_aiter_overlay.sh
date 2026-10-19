#!/usr/bin/env bash
# Pick the AITER nightly wheel that fits the resolved nightly image, build
# docker/Dockerfile.aiter-overlay on top of it with that wheel, and push.
#
# The wheel is chosen by vLLM's own select_aiter_nightly_wheel.py, the selector
# vLLM CI runs for AITER_NIGHTLY=1 builds, run inside the base image so it
# reads that image's ROCm, torch and Python. It takes the newest wheel built
# for exactly that combination; if there is none, this step stops before
# anything is built, pushed or benchmarked, so perf-eval is never handed an
# image whose AITER was compiled against a different torch or ROCm. The
# selector is taken from the same vLLM commit as the image, so it is the one
# vLLM CI ran for that commit.
#
# Inputs (all optional):
#   AITER_WHEEL_URL     pin an exact wheel; still checked against the image
#   IMAGE_REPO, IMAGE_TAG, PUSH_IMAGE, PULL_BASE, EXTRA_IMAGE_TAGS, DOCKERHUB_*
#
# Buildkite meta-data:
#   reads   vllm-commit, overlay-base-image   set by resolve_nightly.sh
#   r/w     aiter-wheel-url   the wheel chosen on the first attempt; a retry
#                             reads it back and installs that same wheel
#   writes  image-ref   read by trigger_perf_eval.sh
#           aiter-version, image-tag   for reference only
#
# Exit status (same as vLLM's aiter-nightly-overlay.sh):
#   1   transient (selector fetch, index fetch, registry); retried once
#   10  no AITER nightly fits this image
#   11  the wheel does not install
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN_SECRET="${DOCKERHUB_TOKEN_SECRET:-dockerhub_token}"
# Pull the base first so a missing/renamed nightly fails here with a clear
# message rather than mid-build. Set false if the agent already has it cached.
PULL_BASE="${PULL_BASE:-true}"
# Space-separated additional tags to publish alongside the primary one.
EXTRA_IMAGE_TAGS="${EXTRA_IMAGE_TAGS:-}"
AITER_WHEEL_URL="${AITER_WHEEL_URL:-}"

if [[ "$PUSH_IMAGE" == "true" && -z "$DOCKERHUB_USER" ]]; then
  echo "^^^ +++"
  echo "DOCKERHUB_USER is not set but PUSH_IMAGE=true." >&2
  exit 1
fi

meta() { buildkite-agent meta-data get "$1"; }

# fail <status> <title> <detail>: log and annotate an AITER failure, then exit.
fail() {
  local status="$1" title="$2" detail="$3"
  echo "+++ :x: AITER nightly: ${title}"
  echo "${detail}" >&2
  # shellcheck disable=SC2016 # the backticks are a literal markdown fence
  printf ':x: **AITER nightly: %s**\n\n```\n%s\n```\n' "${title}" "${detail}" \
    | buildkite-agent annotate --style error --context "aiter-nightly"
  exit "${status}"
}

vllm_commit="$(meta vllm-commit)"
vllm_short="${vllm_commit:0:8}"
base_image="$(meta overlay-base-image)"
selector_url="https://raw.githubusercontent.com/vllm-project/vllm/${vllm_commit}/.buildkite/scripts/rocm/select_aiter_nightly_wheel.py"

# Dockerfile lives in this repo, checked out by the agent. It COPYs nothing, so
# the build context is irrelevant — use the directory it sits in.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dockerfile="${repo_root}/docker/Dockerfile.aiter-overlay"
context_dir="${repo_root}/docker"

if [[ ! -f "$dockerfile" ]]; then
  echo "^^^ +++"
  echo "Overlay Dockerfile not found at ${dockerfile}." >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Fetched first so a bad ref fails in seconds, not after a multi-GB pull.
echo "--- :arrow_down: Fetching the AITER wheel selector from ${selector_url}"
selector="${scratch}/select_aiter_nightly_wheel.py"
curl -fsSL --retry 3 -o "$selector" "$selector_url" \
  || fail 1 "could not fetch the wheel selector" \
    "${selector_url}
vLLM commits before c9e62f13 (2026-10-12) do not have it; a VLLM_COMMIT pin must be a full SHA."

if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "--- :docker: Logging in to Docker Hub as ${DOCKERHUB_USER}"
  docker_hub_login "$DOCKERHUB_USER" "$DOCKERHUB_TOKEN_SECRET"
fi

if [[ "$PULL_BASE" == "true" ]]; then
  echo "--- :arrow_down: Pulling base nightly ${base_image}"
  docker pull "$base_image"
fi

# --- Select the AITER wheel for this image -----------------------------------
# A retry reuses the first attempt's wheel rather than a newer nightly.
pinned="$(buildkite-agent meta-data get aiter-wheel-url --default "")"
pinned="${pinned:-$AITER_WHEEL_URL}"

echo "--- :mag: Selecting the AITER nightly for ${base_image}"
errors="${scratch}/errors"
set +e
out="$(docker run --rm -i --entrypoint python3 "$base_image" \
  -P - ${pinned:+--wheel-url "$pinned"} \
  < "$selector" 2> "$errors")"
status=$?
set -e
cat "$errors" >&2
case "$status" in
  0) ;;
  10) fail 10 "no wheel for this image" "$out" ;;
  *) fail "$status" "could not select a wheel" "$(tail -n 20 "$errors")" ;;
esac
# The first line is the wheel's URL; the rest, the annotation naming it.
aiter_wheel_url="$(head -n 1 <<< "$out")"
note="$(tail -n +2 <<< "$out")"
buildkite-agent meta-data set "aiter-wheel-url" "$aiter_wheel_url"

# Decoded filename, e.g.
#   amd_aiter-0.1.25+rocm7.2.3.torch2.12.ae984f5.d20261008-cp312-cp312-linux_x86_64.whl
aiter_wheel_file="$(python3 -c 'import sys,urllib.parse as u; print(u.unquote(sys.argv[1].split("#")[0].split("/")[-1]))' "$aiter_wheel_url")"
aiter_version=""
aiter_short=""
if [[ "$aiter_wheel_file" =~ ^amd_aiter-([^-]+)-cp[0-9]+- ]]; then
  aiter_version="${BASH_REMATCH[1]}"
fi
# The AITER commit sits right before the .dYYYYMMDD build date.
if [[ "$aiter_version" =~ \.([0-9a-f]{7,40})\.d[0-9]{8}($|\.) ]]; then
  aiter_short="${BASH_REMATCH[1]:0:8}"
fi
if [[ -z "$aiter_short" ]]; then
  echo "^^^ +++"
  echo "Could not read the AITER version and commit from ${aiter_wheel_file}." >&2
  exit 1
fi

# --- Compute the destination tag ---------------------------------------------
# Encodes both inputs so the image is traceable to the exact vLLM nightly and
# AITER wheel it was built from.
if [[ -n "${IMAGE_TAG:-}" ]]; then
  image_tag="$(sanitize_tag_component "$IMAGE_TAG")"
else
  image_tag="nightly-aiter-${aiter_short}-vllm-${vllm_short}"
fi
image_ref="${IMAGE_REPO}:${image_tag}"

buildkite-agent meta-data set "aiter-version" "$aiter_version"
buildkite-agent meta-data set "image-tag" "$image_tag"
buildkite-agent meta-data set "image-ref" "$image_ref"

# The selector's note starts with :warning: when the wheel is stale.
style=info
if [[ "$note" == :warning:* ]]; then
  style=warning
fi
echo "$note" | buildkite-agent annotate --style "$style" --context "aiter-nightly"

echo "--- :hammer: Building ${image_ref}"
echo "Base image   : ${base_image}"
echo "vLLM commit  : ${vllm_commit}"
echo "AITER version: ${aiter_version}"
echo "AITER wheel  : ${aiter_wheel_url}"
df -h "$PWD" || true

build_cmd=(
  docker build
  --file "$dockerfile"
  --tag "$image_ref"
  --build-arg "BASE_IMAGE=${base_image}"
  --build-arg "AITER_WHEEL_URL=${aiter_wheel_url}"
  --build-arg "VLLM_COMMIT=${vllm_commit}"
  --label "aiter.wheel=${aiter_wheel_url}"
  --label "aiter.version=${aiter_version}"
  --label "vllm.commit=${vllm_commit}"
  --label "buildkite.build.url=${BUILDKITE_BUILD_URL:-}"
)

all_tags=("$image_ref")
for tag in $EXTRA_IMAGE_TAGS; do
  all_tags+=("${IMAGE_REPO}:${tag}")
  build_cmd+=(--tag "${IMAGE_REPO}:${tag}")
done

build_cmd+=("$context_dir")
if ! "${build_cmd[@]}"; then
  fail 11 "the wheel does not install" \
    "Installing ${aiter_wheel_file} over ${base_image} failed; see this step's log."
fi

echo "--- :mag: Verifying installed AITER wheel"
docker run --rm --entrypoint cat "$image_ref" /app/versions.txt || true
docker run --rm --entrypoint python3 "$image_ref" -m pip show amd-aiter 2>/dev/null | grep -i '^Version:' || true

echo "--- :mag: Image summary"
docker image inspect "$image_ref" \
  --format 'size={{.Size}} arch={{.Architecture}} created={{.Created}}'

if [[ "$PUSH_IMAGE" != "true" ]]; then
  echo "--- :no_entry: PUSH_IMAGE is '${PUSH_IMAGE}', not pushing"
  buildkite-agent annotate --style warning --context "image" \
    "Built \`${image_ref}\` locally. Not pushed (\`PUSH_IMAGE=${PUSH_IMAGE}\`)."
  exit 0
fi

echo "--- :rocket: Pushing"
for tag in "${all_tags[@]}"; do
  echo "Pushing ${tag}"
  docker push "$tag"
done

digest="$(docker image inspect "$image_ref" \
  --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')"

{
  echo "Pushed **\`${image_ref}\`**"
  echo ""
  echo '```'
  echo "docker pull ${image_ref}"
  echo '```'
  echo "- vLLM commit: \`${vllm_commit}\`"
  echo "- AITER wheel: \`${aiter_version}\`"
  [[ -n "$digest" ]] && echo "- Digest: \`${digest}\`"
} | buildkite-agent annotate --style success --context "image"
