#!/usr/bin/env bash
# Real-download smoke test; affects only a disposable container.
set -Eeuo pipefail

if (($# > 1)) || [[ ${1:-} == -* ]]; then
    printf 'Usage: %s [debian-or-ubuntu-image]\n' "$0" >&2
    exit 1
fi
IMAGE=${1:-debian:bookworm-slim}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONTAINER=''

cleanup() {
    [[ -z $CONTAINER ]] || docker rm --force "$CONTAINER" >/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker info >/dev/null
CONTAINER=$(docker create "$IMAGE" sleep infinity)
docker cp "$SCRIPT_DIR/." "$CONTAINER:/opt/headless-setup"
docker start "$CONTAINER" >/dev/null
ENV_OPTIONS=()
[[ -z ${GITHUB_TOKEN:-} ]] || ENV_OPTIONS+=(--env GITHUB_TOKEN)
docker exec "${ENV_OPTIONS[@]}" "$CONTAINER" bash /opt/headless-setup/tests/smoke.sh
printf '\nContainer smoke test passed (%s).\n' "$IMAGE"
