#!/usr/bin/env bash
set -Eeuo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:?}
out=${MEOWARCH_OUT:?}
jobs=${MEOWARCH_JOBS:-1}
cross_compile=${CROSS_COMPILE:-aarch64-linux-gnu-}
kernel_src="$workspace/kernel"
kernel_work="$out/work/kernel"
artifacts="$out/artifacts"
public_no_modem=${MEOWARCH_PUBLIC_NO_MODEM:-0}

mkdir -p "$out/kernel" "$out/work" "$artifacts/usr"

if [ ! -e "$kernel_work/Makefile" ]; then
	[ ! -e "$kernel_work" ] || { echo "kernel worktree exists but is incomplete: $kernel_work" >&2; exit 1; }
	git -C "$kernel_src" worktree add --detach "$kernel_work" HEAD
fi

copy_kernel_sources() {
	local component=$1
	local source="$workspace/$component/source/kernel"
	[ -d "$source" ] || return 0
	while IFS= read -r -d '' file; do
		local rel=${file#"$source/"}
		install -D -m 0644 "$file" "$kernel_work/$rel"
	done < <(find "$source" -type f -print0)
}

copy_kernel_sources display
copy_kernel_sources audio
copy_kernel_sources touch

components=(display audio touch)
[ "$public_no_modem" -eq 0 ] && components+=(modem)
for component in "${components[@]}"; do
	patch_dir="$workspace/$component/patches"
	[ -d "$patch_dir" ] || continue
	while IFS= read -r -d '' patch; do
		marker="$kernel_work/.meowarch-$component-$(basename "$patch").applied"
		if [ ! -e "$marker" ]; then
			git -C "$kernel_work" apply --check "$patch"
			git -C "$kernel_work" apply "$patch"
			touch "$marker"
		fi
	done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
done

if [ ! -e "$kernel_work/.meowarch-configured" ]; then
	make -C "$kernel_work" ARCH=arm64 LLVM=1 CROSS_COMPILE="$cross_compile" defconfig
	"$kernel_work/scripts/kconfig/merge_config.sh" -m \
		"$kernel_work/.config" "$builder_dir/config/zorn/kernel.fragment"
	make -C "$kernel_work" ARCH=arm64 LLVM=1 CROSS_COMPILE="$cross_compile" olddefconfig
	touch "$kernel_work/.meowarch-configured"
fi

make -C "$kernel_work" ARCH=arm64 LLVM=1 CROSS_COMPILE="$cross_compile" -j"$jobs" Image modules
make -C "$kernel_work" ARCH=arm64 LLVM=1 CROSS_COMPILE="$cross_compile" \
	INSTALL_MOD_PATH="$artifacts/usr" INSTALL_MOD_STRIP=1 modules_install

qcomtee_src="$workspace/modem/source/qcomtee-oot"
qcomtee_work="$out/work/qcomtee-oot"
if [ "$public_no_modem" -eq 0 ] && [ -d "$qcomtee_src" ]; then
	if [ ! -e "$qcomtee_work/Makefile" ]; then
		mkdir -p "$qcomtee_work"
		cp -a "$qcomtee_src"/. "$qcomtee_work/"
	fi
	make -C "$kernel_work" ARCH=arm64 LLVM=1 CROSS_COMPILE="$cross_compile" M="$qcomtee_work" modules
	install -D -m 0644 "$qcomtee_work/qcomtee.ko" "$artifacts/usr/local/lib/zorn/qcomtee.ko"
fi

cp "$kernel_work/arch/arm64/boot/Image" "$out/kernel/Image"
cp "$kernel_work/.config" "$out/kernel/config"
printf '%s\n' "$(make -s -C "$kernel_work" ARCH=arm64 CROSS_COMPILE="$cross_compile" kernelrelease)" >"$out/kernel/release"
printf '%s\n' "kernel artifacts: $out/kernel and $artifacts/usr"
