#!/usr/bin/env bash
set -euo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:-$(CDPATH= cd -- "$builder_dir/.." && pwd)}
image=${MEOWARCH_TOOLCHAIN_IMAGE:-meowarch/zorn-builder:latest}

runtime=${MEOWARCH_CONTAINER_RUNTIME:-}
if [ -z "$runtime" ]; then
	if command -v podman >/dev/null 2>&1; then runtime=podman
	elif command -v docker >/dev/null 2>&1; then runtime=docker
	else
		echo "no podman/docker found; use --native or install a container runtime" >&2
		exit 1
	fi
fi

if ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
	"$runtime" build \
		-f "$builder_dir/toolchain/Containerfile" \
		--platform "${MEOWARCH_CONTAINER_PLATFORM:-linux/arm64}" \
		--build-arg BASE_IMAGE="${MEOWARCH_BASE_IMAGE:-docker.io/agners/archlinuxarm@sha256:1a4dc79f6ff52711be72889cd0e38182d7e2a6c40b257b0a08cc9b5ef9342f32}" \
		-t "$image" "$builder_dir/toolchain"
fi

exec "$runtime" run --rm -it \
	--platform "${MEOWARCH_CONTAINER_PLATFORM:-linux/arm64}" \
	-e MEOWARCH_IN_TOOLCHAIN=1 \
	-e MEOWARCH_WORKSPACE=/workspace \
	-e MEOWARCH_OUT="${MEOWARCH_OUT_CONTAINER:-/workspace/out/zorn}" \
	-v "$workspace:/workspace" \
	-w /workspace \
	"$image" \
	/workspace/builder/build.sh --native "$@"
