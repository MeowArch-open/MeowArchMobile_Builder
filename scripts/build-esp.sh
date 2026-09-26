#!/usr/bin/env bash
set -Eeuo pipefail

builder_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${MEOWARCH_WORKSPACE:?}
out=${MEOWARCH_OUT:?}
esp_out="$out/esp"
dtb_out="$esp_out/dtb"
esp_image="$esp_out/ESP.img"
esp_size=${MEOWARCH_ESP_SIZE_MIB:-512}
esp_uuid=${MEOWARCH_ESP_UUID:-5BE6-B2DF}
esp_serial=${esp_uuid//-/}
root_partuuid=${MEOWARCH_ROOT_PARTUUID:-6fe8724f-4204-4950-b3be-30e7c2cdc7b2}

[[ "$esp_serial" =~ ^[[:xdigit:]]{8}$ ]] || {
	echo "invalid ESP UUID for mformat -N: $esp_uuid (expected 8 hex digits, optionally XXXX-XXXX)" >&2
	exit 1
}

[ -f "$out/kernel/Image" ] || { echo "missing kernel Image: $out/kernel/Image" >&2; exit 1; }
mkdir -p "$dtb_out"

compile_dtb() {
	local source=$1 output=$2
	[ -f "$source" ] || { echo "missing DTS: $source" >&2; exit 1; }
	dtc -q -I dts -O dtb -o "$dtb_out/$output" "$source"
}

# The shipping ESP carries exactly the two device trees the recovery+normal
# GRUB menu references, both from the boot profile in common_rootfs:
#   recovery -> zorn.dtb      : pure base tree, simplefb (GRUB blacklists msm)
#   normal   -> zorn-cam.dtb  : full daily tree (DPU + o11 panel, OV08D10
#                               ultra-wide, iris HW codec, i2c-hub sensors)
# The per-subsystem audio/tdm/display bring-up trees under audio/dts/ are
# experiments; no recovery or normal entry selects them, so they are
# deliberately not compiled into the image.
compile_dtb "$workspace/common_rootfs/profiles/zorn/boot/zorn.dts" zorn.dtb
compile_dtb "$workspace/common_rootfs/profiles/zorn/boot/zorn-cam.dts" zorn-cam.dtb

grub_cfg="$esp_out/grub.cfg"
sed \
	-e "s/@ESP_UUID@/$esp_uuid/g" \
	-e "s/@ROOT_PARTUUID@/$root_partuuid/g" \
	"$builder_dir/config/zorn/grub.cfg.in" >"$grub_cfg"

bootaa64="$esp_out/BOOTAA64.EFI"
prebuilt_grub="$builder_dir/prebuilt/grub/BOOTAA64.EFI"
if [ -f "$prebuilt_grub" ]; then
	# The bundled image was extracted from the physical zorn ESP and contains
	# the arm64-efi GRUB target missing from the host Arch grub package.  The
	# current menu remains external at /EFI/BOOT/grub.cfg.
	cp -f "$prebuilt_grub" "$bootaa64"
else
	grub-mkstandalone \
		-O arm64-efi \
		-o "$bootaa64" \
		--disable-shim-lock \
		--modules="part_gpt fat fdt search_fs_uuid normal configfile linux echo" \
		"boot/grub/grub.cfg=$grub_cfg"
fi

truncate -s "${esp_size}M" "$esp_image"
mformat -i "$esp_image" -F -v ESP -N "$esp_serial" ::
for dir in EFI EFI/BOOT dtb boot boot/grub loader loader/entries; do
	mmd -i "$esp_image" "::$dir"
done
mcopy -i "$esp_image" "$out/kernel/Image" ::/Image
mcopy -i "$esp_image" "$bootaa64" ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "$esp_image" "$grub_cfg" ::/EFI/BOOT/grub.cfg
for dtb in "$dtb_out"/*.dtb; do
	mcopy -i "$esp_image" "$dtb" ::/dtb/$(basename "$dtb")
done

printf '%s\n' "ESP image: $esp_image"
