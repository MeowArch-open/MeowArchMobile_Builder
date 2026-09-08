#!/usr/bin/env bash
set -Eeuo pipefail

workspace=${MEOWARCH_WORKSPACE:?}
artifacts=${MEOWARCH_USERSPACE_ARTIFACTS:?}
jobs=${MEOWARCH_JOBS:-1}
work=${MEOWARCH_OUT:-$workspace/out/zorn}/work/userspace
public_no_modem=${MEOWARCH_PUBLIC_NO_MODEM:-0}
mkdir -p "$artifacts/usr/local/sbin" "$artifacts/usr/local/lib/zorn" "$work"

have() { [ -e "$artifacts/usr/local/sbin/$1" ]; }
install_bin() { install -D -m 0755 "$1" "$artifacts/usr/local/sbin/$2"; }

build_c_simple() {
  local name=$1 source=$2
  have "$name" && return 0
  [ -f "$source" ] || { echo "missing userspace source for $name: $source" >&2; return 1; }
  echo "build userspace: $name"
  cc -O2 -Wall -Wextra -D_GNU_SOURCE "$source" -o "$work/$name"
  install_bin "$work/$name" "$name"
}

build_qrtr() {
  local source="$workspace/modem/services/qrtr"
  local build="$work/qrtr-build"
  local prefix="$work/sysroot/usr"
  [ -f "$prefix/lib/libqrtr.a" ] && return 0
  [ -f "$source/meson.build" ] || { echo "missing qrtr source: $source" >&2; return 1; }
  mkdir -p "$prefix"
  meson setup "$build" "$source" --prefix="$prefix" --default-library=static --buildtype=release
  meson compile -C "$build" -j "$jobs"
  meson install -C "$build"
}

build_hostapd() {
  have hostapd && have hostapd_cli && return 0
  local source="$workspace/wifi/services/hostapd"
  local build="$work/hostapd"
  [ -f "$source/hostapd/Makefile" ] || { echo "missing hostapd source: $source" >&2; return 1; }
  if [ ! -f "$build/.prepared" ]; then
    mkdir -p "$build"
    cp -a "$source/." "$build/"
    cp "$build/hostapd/defconfig" "$build/hostapd/.config"
    touch "$build/.prepared"
  fi
  make -C "$build/hostapd" -j "$jobs" hostapd hostapd_cli
  install_bin "$build/hostapd/hostapd" hostapd
  install_bin "$build/hostapd/hostapd_cli" hostapd_cli
}

build_pd_mapper() {
  have pd-mapper && return 0
  local source="$workspace/modem/services/pd-mapper"
  local build="$work/pd-mapper"
  [ -f "$source/Makefile" ] || { echo "missing pd-mapper source: $source" >&2; return 1; }
  if [ ! -f "$build/Makefile" ]; then cp -a "$source/." "$build/"; fi
  make -C "$build" clean all CC=cc \
    CFLAGS="-O2 -Wall -I$work/sysroot/usr/include" \
    LDFLAGS="-L$work/sysroot/usr/lib"
  install_bin "$build/pd-mapper" pd-mapper
}

build_tqftpserv() {
  have tqftpserv && return 0
  local source="$workspace/modem/services/tqftpserv"
  local build="$work/tqftpserv-build"
  [ -f "$source/meson.build" ] || { echo "missing tqftpserv source: $source" >&2; return 1; }
  export PKG_CONFIG_PATH="$work/sysroot/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  meson setup "$build" "$source" --prefix=/usr --buildtype=release -Dsystemd-unit-prefix=
  meson compile -C "$build" -j "$jobs"
  install_bin "$build/tqftpserv" tqftpserv
}

build_rmtfs() {
  have rmtfs && return 0
  local source="$workspace/modem/services/rmtfs"
  local build="$work/rmtfs"
  [ -f "$source/Makefile" ] || { echo "missing rmtfs source: $source (sync the linux-msm/rmtfs manifest project)" >&2; return 1; }
  if [ ! -f "$build/Makefile" ]; then cp -a "$source/." "$build/"; fi
  make -C "$build" clean all CC=cc \
    CFLAGS="-O2 -Wall -I$work/sysroot/usr/include" \
    LDFLAGS="-L$work/sysroot/usr/lib"
  install_bin "$build/rmtfs" rmtfs
}

build_zorn_qrtr() {
  have zorn-qmiprobe && return 0
  local source="$workspace/modem/services/zorn/src/zorn-qmiprobe.c"
  [ -f "$source" ] || { echo "missing zorn-qmiprobe source: $source" >&2; return 1; }
  cc -O2 -Wall -D_GNU_SOURCE -I"$work/sysroot/usr/include" \
    "$source" "$work/sysroot/usr/lib/libqrtr.a" -lpthread -o "$work/zorn-qmiprobe"
  install_bin "$work/zorn-qmiprobe" zorn-qmiprobe
}

build_zorn_wds() {
  have zorn-wds && return 0
  local source="$workspace/modem/services/zorn/src/zorn-wds.c"
  local flags
  [ -f "$source" ] || { echo "missing zorn-wds source: $source" >&2; return 1; }
  flags=$(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0 gobject-2.0)
  cc -O2 -Wall -D_GNU_SOURCE $flags "$source" -o "$work/zorn-wds"
  install_bin "$work/zorn-wds" zorn-wds
}

build_zorn_minkd() {
  have zorn-minkd && return 0
  local source="$workspace/modem/services/zorn/src/zorn-minkd.c"
  local mink="$workspace/modem/services/mink"
  local qrtr="$workspace/modem/services/qrtr"
  local stage="$work/minkd"
  [ -f "$source" ] || { echo "missing zorn-minkd source: $source" >&2; return 1; }
  [ -d "$mink/minkipc" ] && [ -d "$mink/qcomtee-lib" ] || {
    echo "missing Mink source tree for zorn-minkd: $mink" >&2
    return 1
  }
  mkdir -p "$stage/src" "$stage/build/qrtr"
  ln -sfn "$mink/qcomtee-lib" "$stage/qcomtee-lib"
  ln -sfn "$mink/minkipc" "$stage/minkipc"
  ln -sfn "$mink/shim" "$stage/minkshim"
  ln -sfn "$mink/generated" "$stage/minkgen"
  ln -sfn "$qrtr" "$stage/src/qrtr"
  cp "$source" "$stage/src/zorn-minkd.c"
  ln -sfn "$work/sysroot/usr/lib/libqrtr.a" "$stage/build/qrtr/libqrtr.a"
  cp "$workspace/modem/services/zorn/build/build-minkd.sh" "$stage/build-minkd.sh"
  sed -i \
    -e 's|^S=.*|S=/|' \
    -e 's|^G=.*|G=$(dirname "$(gcc -print-libgcc-file-name)")|' \
    -e 's|^CC=.*|CC="clang --target=aarch64-linux-gnu --sysroot=$S -static-libgcc -fuse-ld=lld"|' \
    "$stage/build-minkd.sh"
  (cd "$stage" && sh ./build-minkd.sh)
  install_bin "$stage/build/zorn-minkd" zorn-minkd
}

build_fastrpc() {
  have fastrpc-audiopd && return 0
  local source="$workspace/audio/services/bringup/fastrpc-audiopd.c"
  [ -f "$source" ] || { echo "missing fastrpc-audiopd source: $source" >&2; return 1; }
  cc -O2 -Wall -Wextra "$source" -o "$work/fastrpc-audiopd"
  install_bin "$work/fastrpc-audiopd" fastrpc-audiopd
}

build_fastrpc
build_hostapd
if [ "$public_no_modem" -eq 0 ]; then
  if ! have pd-mapper || ! have tqftpserv || ! have rmtfs || \
     ! have zorn-qmiprobe || ! have zorn-wds || ! have zorn-minkd; then
    build_qrtr
  fi
  build_pd_mapper
  build_tqftpserv
  build_rmtfs
  build_zorn_qrtr
  build_zorn_wds
  build_c_simple zorn-diag "$workspace/modem/services/zorn/src/zorn-diag.c"
  build_c_simple zorn-efs "$workspace/modem/services/zorn/src/zorn-efs.c"
  build_zorn_minkd
fi

printf '%s\n' "userspace artifacts ready: $artifacts/usr/local/sbin"
