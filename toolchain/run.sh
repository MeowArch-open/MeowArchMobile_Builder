#!/usr/bin/env bash
set -euo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:-$(CDPATH= cd -- "$builder_dir/.." && pwd)}
image=${MEOWARCH_TOOLCHAIN_IMAGE:-meowarch/zorn-builder:latest}
platform=${MEOWARCH_CONTAINER_PLATFORM:-linux/arm64}
base_image=${MEOWARCH_BASE_IMAGE:-docker.io/agners/archlinuxarm@sha256:cd2eb76b34be8dd6ae52ba4e3531228a3a6f754f82d05fadbb30fb25036d1e05}

runtime=${MEOWARCH_CONTAINER_RUNTIME:-}
if [ -z "$runtime" ]; then
	if command -v podman >/dev/null 2>&1; then runtime=podman
	elif command -v docker >/dev/null 2>&1; then runtime=docker
	else
		echo "no podman/docker found; use --native or install a container runtime" >&2
		exit 1
	fi
fi

if [ "$platform" = linux/arm64 ] && [ "${MEOWARCH_AUTO_BINFMT:-1}" = 1 ]; then
	if ! "$runtime" run --rm --platform "$platform" "$base_image" /bin/true >/dev/null 2>&1; then
		echo "ARM64 binfmt is unavailable; registering qemu-aarch64 through tonistiigi/binfmt"
		"$runtime" run --privileged --rm tonistiigi/binfmt:latest --install arm64
	fi
	"$runtime" run --rm --platform "$platform" "$base_image" /bin/true >/dev/null 2>&1 || {
		echo "ARM64 containers still cannot execute; install/enable Docker binfmt or use --native on an ARM64 host" >&2
		exit 1
	}
fi

image_arch=$("$runtime" image inspect --format '{{.Architecture}}' "$image" 2>/dev/null || true)
if [ "$image_arch" != arm64 ] && [ "$image_arch" != aarch64 ]; then
	"$runtime" build \
		-f "$builder_dir/toolchain/Containerfile" \
		--platform "$platform" \
		--build-arg BASE_IMAGE="$base_image" \
		-t "$image" "$builder_dir/toolchain"
fi

exec "$runtime" run --rm -it \
	--platform "$platform" \
	-e MEOWARCH_IN_TOOLCHAIN=1 \
	-e MEOWARCH_WORKSPACE=/workspace \
	-e MEOWARCH_OUT="${MEOWARCH_OUT_CONTAINER:-/workspace/out/zorn}" \
	-v "$workspace:/workspace" \
	-w /workspace \
	"$image" \
	/workspace/builder/build.sh --native "$@"
