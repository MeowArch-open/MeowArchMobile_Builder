#!/usr/bin/env bash
set -euo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:-$(CDPATH= cd -- "$builder_dir/.." && pwd)}
image=${MEOWARCH_TOOLCHAIN_IMAGE:-meowarch/zorn-builder:latest}
platform=${MEOWARCH_CONTAINER_PLATFORM:-linux/arm64}
base_image=${MEOWARCH_BASE_IMAGE:-docker.io/agners/archlinuxarm@sha256:cd2eb76b34be8dd6ae52ba4e3531228a3a6f754f82d05fadbb30fb25036d1e05}
proxy=${MEOWARCH_PROXY:-}
no_proxy=${MEOWARCH_NO_PROXY:-}
proxy_host_network=${MEOWARCH_PROXY_HOST_NETWORK:-1}

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
	build_network_args=()
	build_proxy_args=()
	if [ -n "$proxy" ]; then
		[ "$proxy_host_network" = 1 ] && build_network_args+=(--network host)
		for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
			build_proxy_args+=(--build-arg "$name=$proxy")
		done
		build_proxy_args+=(--build-arg "NO_PROXY=$no_proxy" --build-arg "no_proxy=$no_proxy")
	fi
	"$runtime" build \
		-f "$builder_dir/toolchain/Containerfile" \
		--platform "$platform" \
		--build-arg BASE_IMAGE="$base_image" \
		"${build_network_args[@]}" "${build_proxy_args[@]}" \
		-t "$image" "$builder_dir/toolchain"
fi

run_args=(--rm -it --platform "$platform")
if [ -n "$proxy" ]; then
	[ "$proxy_host_network" = 1 ] && run_args+=(--network host)
	for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
		run_args+=(-e "$name=$proxy")
	done
	run_args+=(-e "NO_PROXY=$no_proxy" -e "no_proxy=$no_proxy")
fi

exec "$runtime" run "${run_args[@]}" \
	-e MEOWARCH_IN_TOOLCHAIN=1 \
	-e MEOWARCH_WORKSPACE=/workspace \
	-e MEOWARCH_OUT="${MEOWARCH_OUT_CONTAINER:-/workspace/out/zorn}" \
	-v "$workspace:/workspace" \
	-w /workspace \
	"$image" \
	/workspace/builder/build.sh --native "$@"
