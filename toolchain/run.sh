#!/usr/bin/env bash
set -euo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:-$(CDPATH= cd -- "$builder_dir/.." && pwd)}
out_host=${MEOWARCH_OUT:-$workspace/out/zorn}
prebuilt_host=${MEOWARCH_PREBUILT:-}
image=${MEOWARCH_TOOLCHAIN_IMAGE:-meowarch/zorn-builder:latest}
platform=${MEOWARCH_CONTAINER_PLATFORM:-linux/arm64}
base_image=${MEOWARCH_BASE_IMAGE:-docker.io/agners/archlinuxarm@sha256:cd2eb76b34be8dd6ae52ba4e3531228a3a6f754f82d05fadbb30fb25036d1e05}
proxy=${MEOWARCH_PROXY:-}
no_proxy=${MEOWARCH_NO_PROXY:-}
proxy_host_network=${MEOWARCH_PROXY_HOST_NETWORK:-0}
forward_args=()
rootfs_only=0
public_no_modem=${MEOWARCH_PUBLIC_NO_MODEM:-0}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--workspace) workspace=$2; shift 2 ;;
		--out) out_host=$2; shift 2 ;;
		--prebuilt) prebuilt_host=$2; shift 2 ;;
		--proxy) proxy=$2; forward_args+=(--proxy "$2"); shift 2 ;;
		--rootfs-only) rootfs_only=1; shift ;;
		--public-no-modem) public_no_modem=1; forward_args+=(--public-no-modem); shift ;;
		--native) shift ;;
		*) forward_args+=("$1"); shift ;;
	esac
done

workspace=$(CDPATH= cd -- "$workspace" && pwd)
mkdir -p "$(dirname -- "$out_host")"
out_host=$(CDPATH= cd -- "$(dirname -- "$out_host")" && pwd)/$(basename -- "$out_host")

map_workspace_path() {
	local path=$1
	if [ "$path" = "$workspace" ]; then
		printf '/workspace\n'
	elif [[ "$path" == "$workspace/"* ]]; then
		printf '/workspace/%s\n' "${path#"$workspace/"}"
	else
		return 1
	fi
}

out_container=/workspace/out/zorn
extra_mounts=()
if out_container=$(map_workspace_path "$out_host"); then
	:
else
	mkdir -p "$out_host"
	out_container=/meowarch-out
	extra_mounts+=(-v "$out_host:$out_container")
fi

prebuilt_container=
if [ -n "$prebuilt_host" ]; then
	prebuilt_host=$(CDPATH= cd -- "$prebuilt_host" && pwd)
	if prebuilt_container=$(map_workspace_path "$prebuilt_host"); then
		:
	else
	prebuilt_container=/meowarch-prebuilt
		extra_mounts+=(-v "$prebuilt_host:$prebuilt_container:ro")
	fi
	forward_args+=(--prebuilt "$prebuilt_container")
fi

runtime=${MEOWARCH_CONTAINER_RUNTIME:-}
if [ -z "$runtime" ]; then
	if command -v podman >/dev/null 2>&1; then runtime=podman
	elif command -v docker >/dev/null 2>&1; then runtime=docker
	else
		echo "no podman/docker found; use --native or install a container runtime" >&2
		exit 1
	fi
fi

host_arch=$(uname -m)
if [ "$platform" = linux/arm64 ] && [ "$host_arch" != aarch64 ] && [ "$host_arch" != arm64 ] && [ "${MEOWARCH_AUTO_BINFMT:-1}" = 1 ]; then
	if ! "$runtime" run --rm --platform "$platform" "$base_image" /bin/true >/dev/null 2>&1; then
		echo "warning: ARM64 probe failed; registering qemu-aarch64 through tonistiigi/binfmt" >&2
		"$runtime" run --privileged --rm tonistiigi/binfmt:latest --install arm64
	fi
	if ! "$runtime" run --rm --platform "$platform" "$base_image" /bin/true >/dev/null 2>&1; then
		echo "warning: ARM64 base-image probe still fails; continuing and letting Docker build/run report the actual error" >&2
	fi
fi

toolchain_fingerprint=$(
	{
		printf 'platform=%s\nbase_image=%s\n' "$platform" "$base_image"
		sha256sum "$builder_dir/toolchain/Containerfile" "$builder_dir/toolchain/packages.txt"
	} | sha256sum | awk '{print $1}'
)
image_arch=$("$runtime" image inspect --format '{{.Architecture}}' "$image" 2>/dev/null || true)
image_fingerprint=$("$runtime" image inspect --format '{{ index .Config.Labels "org.meowarch.toolchain-fingerprint" }}' "$image" 2>/dev/null || true)
if [ "${MEOWARCH_REBUILD_IMAGE:-0}" = 1 ] || {
	[ "$image_arch" != arm64 ] && [ "$image_arch" != aarch64 ]
} || [ "$image_fingerprint" != "$toolchain_fingerprint" ]; then
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
		--label "org.meowarch.toolchain-fingerprint=$toolchain_fingerprint" \
		"${build_network_args[@]}" "${build_proxy_args[@]}" \
		-t "$image" "$builder_dir/toolchain"
fi

run_args=(--rm --platform "$platform")
if [ -t 0 ] && [ -t 1 ] && [ "${CI:-}" != true ]; then
	run_args+=(-it)
fi
if [ -n "$proxy" ]; then
	[ "$proxy_host_network" = 1 ] && run_args+=(--network host)
	for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
		run_args+=(-e "$name=$proxy")
	done
	run_args+=(-e "NO_PROXY=$no_proxy" -e "no_proxy=$no_proxy")
fi

if [ "$rootfs_only" -eq 1 ]; then
	container_command=(/workspace/builder/scripts/build-rootfs.sh)
else
	container_command=(/workspace/builder/build.sh --native \
		--workspace /workspace --out "$out_container" \
		"${forward_args[@]}")
fi

exec "$runtime" run "${run_args[@]}" \
	-e MEOWARCH_IN_TOOLCHAIN=1 \
	-e MEOWARCH_HOST_UID="$(id -u)" \
	-e MEOWARCH_HOST_GID="$(id -g)" \
	-e MEOWARCH_WORKSPACE=/workspace \
	-e MEOWARCH_OUT="$out_container" \
	-e MEOWARCH_PREBUILT="${prebuilt_container:-}" \
	-e MEOWARCH_PUBLIC_NO_MODEM="$public_no_modem" \
	"${extra_mounts[@]}" \
	-v "$workspace:/workspace" \
	-w /workspace \
	"$image" \
	"${container_command[@]}"
