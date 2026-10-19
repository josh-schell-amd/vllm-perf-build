#!/usr/bin/env bash
# Install the AITER nightly wheel that fits the resolved nightly image (picked by
# vLLM's select_aiter_nightly_wheel.py) over that image, and push the result
# unless PUSH_IMAGE=false.
#
# Exit status, as in vLLM's aiter-nightly-overlay.sh:
#   1   transient (fetch or registry error); retried once
#   10  no AITER nightly fits this image
#   11  the wheel does not install
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
DOCKERHUB_TOKEN_SECRET="${DOCKERHUB_TOKEN_SECRET:-dockerhub_token}"

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

echo "--- :arrow_down: Fetching the AITER wheel selector from ${selector_url}"
selector="${scratch}/select_aiter_nightly_wheel.py"
curl -fsSL --retry 3 -o "$selector" "$selector_url" \
  || fail 1 "could not fetch the wheel selector" "${selector_url}"

if [[ "$PUSH_IMAGE" == "true" ]]; then
  # Set on this step in pipeline.aiter-nightly.yml.
  echo "--- :docker: Logging in to Docker Hub as ${DOCKERHUB_USER}"
  docker_hub_login "$DOCKERHUB_USER" "$DOCKERHUB_TOKEN_SECRET"
fi

echo "--- :arrow_down: Pulling base nightly ${base_image}"
docker pull "$base_image"

# --- Select the AITER wheel for this image -----------------------------------
# Set below on the first attempt, so a retry reuses that wheel, not a newer
# nightly.
pinned="$(buildkite-agent meta-data get aiter-wheel-url --default "")"

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

# The image is tagged with the AITER commit, read from the wheel's filename:
#   amd_aiter-0.1.25+rocm7.2.3.torch2.12.ae984f5.d20261008-cp312-cp312-linux_x86_64.whl
aiter_wheel_file="${aiter_wheel_url%%#*}"
aiter_wheel_file="${aiter_wheel_file##*/}"
aiter_wheel_file="${aiter_wheel_file//%2B/+}"
if [[ ! "$aiter_wheel_file" =~ ^amd_aiter-([^-]*\.([0-9a-f]{7,40})\.d[0-9]{8}[^-]*)-cp ]]; then
  fail 1 "could not read the AITER commit" "${aiter_wheel_file}"
fi
aiter_version="${BASH_REMATCH[1]}"
aiter_short="${BASH_REMATCH[2]:0:8}"

if [[ -n "${IMAGE_TAG:-}" ]]; then
  image_tag="$(sanitize_tag_component "$IMAGE_TAG")"
else
  image_tag="nightly-aiter-${aiter_short}-vllm-${vllm_short}"
fi
image_ref="${IMAGE_REPO}:${image_tag}"
# Read by trigger_perf_eval.sh.
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
  "$context_dir"
)

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

echo "--- :rocket: Pushing ${image_ref}"
docker push "$image_ref"

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
