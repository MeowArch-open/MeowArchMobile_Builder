#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || {
	echo "run as root: sudo $0" >&2
	exit 1
}
case "$(uname -m)" in
	aarch64|arm64) ;;
	*) echo "Ubuntu native dependencies require ARM64; got $(uname -m)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	bc bison build-essential ca-certificates clang cmake cpio curl \
	device-tree-compiler dosfstools e2fsprogs flex git gzip lld llvm make meson \
	mtools nasm ninja-build patch perl pkg-config python3 python3-pip \
	python3-venv rsync tar unzip uuid-dev zlib1g-dev zstd
rm -rf /var/lib/apt/lists/*
