#!/usr/bin/env bash
set -euo pipefail

case "$(uname -m)" in
	aarch64|arm64) ;;
	*) echo "native build requires ARM64; got $(uname -m)" >&2; exit 1 ;;
esac

required=(
	bc bison clang cmake cpio curl dtc flex gcc git gzip ld.lld llvm-nm
	llvm-objcopy llvm-readelf make meson mformat mkfs.ext4 nasm ninja patch
	perl pip3 python3 rsync sha256sum tar unzip zstd
)
missing=()
for command in "${required[@]}"; do
	command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
if [ "${#missing[@]}" -ne 0 ]; then
	echo "missing native build commands:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "On Ubuntu 24.04 ARM64 run: sudo builder/toolchain/install-native-ubuntu.sh" >&2
	exit 1
fi

command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 || {
	echo "docker or podman is required for the Arch ARM rootfs stage" >&2
	exit 1
}
