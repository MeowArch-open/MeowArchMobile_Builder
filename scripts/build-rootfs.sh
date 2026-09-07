#!/usr/bin/env bash
set -Eeuo pipefail

workspace=${MEOWARCH_WORKSPACE:?}
out=${MEOWARCH_OUT:?}
common="$workspace/common_rootfs"
rootfs="$out/rootfs/tree"
aur_out="$out/aur"
aur_work="$out/work/aur"
artifacts="$out/artifacts"

[ -d "$common" ] || { echo "missing common_rootfs: $common" >&2; exit 1; }
mkdir -p "$out/rootfs" "$out/work" "$aur_out" "$artifacts"

if [ ! -f "$aur_out/.complete" ] || [ "${MEOWARCH_REBUILD_AUR:-0}" = 1 ]; then
	if [ "$(id -u)" -eq 0 ]; then
		if id meowarch >/dev/null 2>&1; then
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

"$common/scripts/build-rootfs.sh" \
	--root "$rootfs" \
	--pacman-conf "${MEOWARCH_PACMAN_CONF:-/etc/pacman.conf}" \
	--aur-dir "$aur_out" \
	--components "$workspace" \
	--artifacts "$artifacts"

required=(
	/usr/local/sbin/fastrpc-audiopd
	/usr/local/sbin/hostapd
	/usr/local/sbin/hostapd_cli
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
