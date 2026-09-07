#!/usr/bin/env bash
set -Eeuo pipefail

workspace=${MEOWARCH_WORKSPACE:?}
out=${MEOWARCH_OUT:?}
uefi="$workspace/uefi/Project_Mu"

[ -f "$uefi/build_uefi.py" ] || { echo "missing Project Mu checkout: $uefi" >&2; exit 1; }
mkdir -p "$out/uefi"

export CLANGPDB_AARCH64_PREFIX="${CLANGPDB_AARCH64_PREFIX:-${CROSS_COMPILE:-aarch64-linux-gnu-}}"

if [ -f "$uefi/pip-requirements.txt" ]; then
	python3 -m pip install --disable-pip-version-check --break-system-packages \
		-r "$uefi/pip-requirements.txt"
fi

pushd "$uefi" >/dev/null
python3 build_uefi.py -d zorn -m 0 -c
python3 build_uefi.py -d zorn -m 1

# zorn.toml currently declares Android boot images.  A raw .bin is only
# produced when the Project Mu device config declares a [payload] output.
for artifact in Mu-zorn-0.img Mu-zorn-1.img; do
	[ -f "$artifact" ] || { echo "UEFI artifact missing: $uefi/$artifact" >&2; exit 1; }
	cp -f "$artifact" "$out/uefi/"
done

for artifact in Mu-zorn-0.bin Mu-zorn-1.bin; do
	[ -f "$artifact" ] || continue
	cp -f "$artifact" "$out/uefi/"
done
popd >/dev/null

printf '%s\n' "UEFI artifacts: $out/uefi"
