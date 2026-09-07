#!/usr/bin/env bash
set -Eeuo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace=${MEOWARCH_WORKSPACE:-$(CDPATH= cd -- "$builder_dir/.." && pwd)}
out=${MEOWARCH_OUT:-$workspace/out/zorn}
jobs=${MEOWARCH_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
prebuilt=
proxy=${MEOWARCH_PROXY:-}
native=0
skip_kernel=0
skip_uefi=0
skip_rootfs=0
skip_esp=0

usage() {
	cat <<'EOF'
usage: builder/build.sh [options]

  --workspace DIR   manifest workspace
  --out DIR         output directory
  --jobs N          parallel jobs
  --prebuilt DIR    rootfs-shaped userspace artifacts
  --proxy URL       host HTTP/HTTPS proxy for build and container network
  --skip-kernel     reuse the existing kernel/artifacts output
  --skip-uefi       reuse the existing UEFI output
  --skip-rootfs     reuse the existing rootfs output
  --skip-esp        reuse the existing ESP output
  --native          do not enter the bundled toolchain container
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--workspace) workspace=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		--jobs) jobs=$2; shift 2 ;;
		--prebuilt) prebuilt=$2; shift 2 ;;
		--proxy) proxy=$2; shift 2 ;;
		--skip-kernel) skip_kernel=1; shift ;;
		--skip-uefi) skip_uefi=1; shift ;;
		--skip-rootfs) skip_rootfs=1; shift ;;
		--skip-esp) skip_esp=1; shift ;;
		--native) native=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

export MEOWARCH_WORKSPACE="$workspace"
export MEOWARCH_OUT="$out"
export MEOWARCH_JOBS="$jobs"
export MEOWARCH_PREBUILT="$prebuilt"
export MEOWARCH_PROXY="$proxy"

if [ "${MEOWARCH_IN_TOOLCHAIN:-0}" != 1 ] && [ "$native" -eq 0 ]; then
	[ -x "$workspace/toolchain/fetch.sh" ] || { echo "missing host toolchain project: $workspace/toolchain" >&2; exit 1; }
	toolchain_root="$out/work/host-toolchain"
	if [ ! -f "$toolchain_root/env.sh" ]; then
		MEOWARCH_PROXY="$proxy" "$workspace/toolchain/fetch.sh" --root "$toolchain_root"
	fi
	# shellcheck disable=SC1091
	. "$toolchain_root/env.sh"

	if [ "$skip_kernel" -eq 0 ]; then "$builder_dir/scripts/build-kernel.sh"; fi
	if [ "$skip_uefi" -eq 0 ]; then "$builder_dir/scripts/build-uefi.sh"; fi
	if [ "$skip_rootfs" -eq 0 ]; then
		"$builder_dir/toolchain/run.sh" --rootfs-only
	fi
	if [ "$skip_esp" -eq 0 ]; then "$builder_dir/scripts/build-esp.sh"; fi
	printf '%s\n' "builder complete: $out"
	find "$out" -maxdepth 2 -type f -printf '%P %s bytes\n' | sort
	exit 0
fi

case "$(uname -m)" in
	aarch64|arm64) ;;
	*) echo "builder requires an aarch64 toolchain environment; got $(uname -m)" >&2; exit 1 ;;
esac

[ -d "$workspace/kernel" ] || { echo "missing manifest project: $workspace/kernel" >&2; exit 1; }
[ -d "$workspace/common_rootfs" ] || { echo "missing manifest project: $workspace/common_rootfs" >&2; exit 1; }
mkdir -p "$out"

if [ "${MEOWARCH_IN_TOOLCHAIN:-0}" = 1 ]; then
	for project in kernel common display audio touch modem wifi common_rootfs builder uefi/Project_Mu; do
		git config --global --add safe.directory "$workspace/$project" 2>/dev/null || true
	done
fi

if [ "$skip_kernel" -eq 0 ]; then
	"$builder_dir/scripts/build-kernel.sh"
fi
if [ "$skip_uefi" -eq 0 ]; then
	"$builder_dir/scripts/build-uefi.sh"
fi
if [ "$skip_rootfs" -eq 0 ]; then
	"$builder_dir/scripts/build-rootfs.sh"
fi
if [ "$skip_esp" -eq 0 ]; then
	"$builder_dir/scripts/build-esp.sh"
fi

printf '%s\n' "builder complete: $out"
find "$out" -maxdepth 2 -type f -printf '%P %s bytes\n' | sort
