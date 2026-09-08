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

# Project Mu's mu_nasm NuGet restore cannot execute on Linux ARM64 even though
# the package has a Linux-ARM-64 payload. Native builds already provide the
# matching NASM tools, so publish them through the extdep contract before
# stuart_setup verifies dependencies.
case "$(uname -m)" in
	aarch64|arm64)
		descriptor="$uefi/Mu_Basecore/BaseTools/Bin/nasm_ext_dep.yaml"
		if [ -f "$descriptor" ]; then
			version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$descriptor")
			[ -n "$version" ] || { echo "cannot read mu_nasm version: $descriptor" >&2; exit 1; }
			nasm_extdep="${descriptor%/*}/mu_nasm_extdep"
			install -D -m 0755 "$(command -v nasm)" "$nasm_extdep/Linux-ARM-64/nasm"
			if command -v ndisasm >/dev/null 2>&1; then
				install -D -m 0755 "$(command -v ndisasm)" "$nasm_extdep/Linux-ARM-64/ndisasm"
			fi
			printf 'version: "%s"\n' "$version" >"$nasm_extdep/extdep_state.yaml"
		fi
		;;
esac

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
