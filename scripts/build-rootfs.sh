#!/usr/bin/env bash
set -Eeuo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:?}
out=${MEOWARCH_OUT:?}
common="$workspace/common_rootfs"
rootfs="$out/rootfs/tree"
aur_out="$out/aur"
aur_work="$out/work/aur"
artifacts="$out/artifacts"
protected_package_dir=${MEOWARCH_PROTECTED_PACKAGE_DIR:-$workspace/protected-pkgs}
protected_package_repo="$workspace/protected_packages"
compat_package_dir=${MEOWARCH_COMPAT_PACKAGE_DIR:-$workspace/compat-pkgs}
public_no_modem=${MEOWARCH_PUBLIC_NO_MODEM:-0}

restore_host_ownership() {
	if [ "$(id -u)" -eq 0 ] && [ -n "${MEOWARCH_HOST_UID:-}" ] && [ -n "${MEOWARCH_HOST_GID:-}" ]; then
		# The host only needs ownership of the output root to create later stage
		# directories. Do not rewrite ownership inside the assembled rootfs.
		chown "$MEOWARCH_HOST_UID:$MEOWARCH_HOST_GID" "$out"
	fi
}
trap restore_host_ownership EXIT

[ -d "$common" ] || { echo "missing common_rootfs: $common" >&2; exit 1; }
mkdir -p "$out/rootfs" "$out/work" "$aur_out" "$aur_work" "$artifacts"

if [ ! -f "$aur_out/.complete" ] || [ "${MEOWARCH_REBUILD_AUR:-0}" = 1 ]; then
	if [ "$(id -u)" -eq 0 ]; then
		if id meowarch >/dev/null 2>&1; then
			# The output directories above were created by root.  AUR recipes
			# must run as meowarch and copy their packages into aur_out.
			chown -R meowarch:meowarch "$aur_out" "$aur_work"
			runuser -u meowarch -- env \
				AUR_OUT="$aur_out" AUR_WORKDIR="$aur_work" \
				"$common/scripts/build-aur.sh"
		else
			echo "AUR build must run as a non-root user (missing user meowarch)" >&2
			exit 1
		fi
	else
		AUR_OUT="$aur_out" AUR_WORKDIR="$aur_work" "$common/scripts/build-aur.sh"
	fi
	touch "$aur_out/.complete"
fi

if [ -n "${MEOWARCH_PREBUILT:-}" ]; then
	[ -d "$MEOWARCH_PREBUILT" ] || { echo "missing prebuilt artifacts: $MEOWARCH_PREBUILT" >&2; exit 1; }
	rsync -a "$MEOWARCH_PREBUILT"/ "$artifacts"/
fi

MEOWARCH_USERSPACE_ARTIFACTS="$artifacts" \
	"$builder_dir/scripts/build-userspace.sh"

if [ -x "$protected_package_repo/fetch.sh" ] && [ "${MEOWARCH_FETCH_PROTECTED:-1}" = 1 ]; then
	"$protected_package_repo/fetch.sh" --out "$protected_package_dir"
fi

rootfs_args=( \
	--root "$rootfs" \
	--pacman-conf "${MEOWARCH_PACMAN_CONF:-/etc/pacman.conf}" \
	--aur-dir "$aur_out" \
	--components "$workspace" \
	--artifacts "$artifacts"
)
if [ -d "$protected_package_dir" ]; then
	rootfs_args+=(--protected-package-dir "$protected_package_dir")
fi
if [ -d "$compat_package_dir" ]; then
	rootfs_args+=(--compat-package-dir "$compat_package_dir")
fi
[ "$public_no_modem" -eq 1 ] && rootfs_args+=(--public-no-modem)
"$common/scripts/build-rootfs.sh" "${rootfs_args[@]}"

required=(
	/usr/local/sbin/fastrpc-audiopd
	/usr/local/sbin/hostapd
	/usr/local/sbin/hostapd_cli
)
if [ "$public_no_modem" -eq 0 ]; then
	required+=(
		/usr/local/sbin/pd-mapper
		/usr/local/sbin/rmtfs
		/usr/local/sbin/tqftpserv
		/usr/local/sbin/zorn-diag
		/usr/local/sbin/zorn-efs
		/usr/local/sbin/zorn-minkd
		/usr/local/sbin/zorn-qmiprobe
		/usr/local/sbin/zorn-wds
		/usr/local/lib/zorn/qcomtee.ko
	)
fi
missing=()
for path in "${required[@]}"; do
	[ -e "$rootfs$path" ] || missing+=("$path")
done
if [ "${#missing[@]}" -ne 0 ]; then
	echo "rootfs is incomplete; supply compiled userspace with --prebuilt:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	exit 1
fi

size_mb=${MEOWARCH_ROOTFS_SIZE_MB:-0}
if [ "$size_mb" -le 0 ]; then
	used_mb=$(du -sm "$rootfs" | awk '{print $1}')
	size_mb=$((used_mb + 1024))
	[ "$size_mb" -ge 2048 ] || size_mb=2048
fi

image="$out/rootfs/rootfs.img"
truncate -s "${size_mb}M" "$image"
mkfs.ext4 -F -L ARCH -d "$rootfs" "$image" >/dev/null

printf '%s\n' "rootfs image: $image (${size_mb} MiB)"
