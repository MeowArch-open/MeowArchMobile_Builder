# MeowArch zorn image builder

This repository is the build layer pulled by
`MeowArchMobile_Manifest`. It consumes the sibling projects checked out by
repo and produces a release directory containing:

```text
out/zorn/
├── esp/ESP.img
├── uefi/Mu-zorn-0.img
├── uefi/Mu-zorn-1.img
├── uefi/Mu-zorn-0.bin
├── uefi/Mu-zorn-1.bin
├── rootfs/rootfs.img
└── artifacts/                 compiled kernel/modules/userspace inputs
```

## Toolchain policy

`build.sh` uses `toolchain/run.sh` by default. That builds/runs a pinned Arch
Linux ARM container (`agners/archlinuxarm`, ARM64 digest) described by
`toolchain/Containerfile`, so the host's compiler,
pacman, dtc, mkfs, GRUB and Python packages are not used as the build toolchain.
The only host dependency is a container runtime (`podman` or `docker`) capable
of running an ARM64 container. On an x86 Docker host, the wrapper automatically
registers `qemu-aarch64` through `tonistiigi/binfmt` using a privileged helper
container. Set `MEOWARCH_AUTO_BINFMT=0` to disable that behavior, or set
`MEOWARCH_TOOLCHAIN_IMAGE`/`MEOWARCH_BASE_IMAGE` to use local image mirrors.

Proxy traffic uses the normal Docker bridge network by default. Pass the host's
LAN address in `--proxy`; do not use `127.0.0.1` unless the proxy is reachable
from the container namespace. Set `MEOWARCH_PROXY_HOST_NETWORK=1` only when the
host-network mode is known to work with the local Docker setup.

For an already prepared Arch ARM build environment, `--native` skips the
container wrapper. This is an explicit escape hatch, not the default.

## Build

From the root of a manifest checkout:

```sh
repo sync -j8 -g default,private,uefi
./builder/build.sh --proxy http://192.168.1.100:7890
```

Useful options:

```text
--workspace DIR       manifest workspace (default: builder's parent)
--out DIR             output directory (default: workspace/out/zorn)
--jobs N              parallel build jobs
--skip-kernel         reuse out/zorn/kernel and artifacts
--skip-uefi           reuse out/zorn/uefi
--skip-rootfs         reuse out/zorn/rootfs
--skip-esp            reuse out/zorn/esp
--prebuilt DIR        rootfs-shaped userspace artifacts to install
--proxy URL            host LAN HTTP/HTTPS proxy for Docker build and container network
--native              do not enter the bundled toolchain container
```

## Build stages

1. `build-kernel.sh` creates a detached worktree from the locked Kernel
   project, copies each subsystem's new kernel source, applies the subsystem
   patches, merges `config/zorn/kernel.fragment`, builds `Image` and modules,
   and builds the qcomtee out-of-tree module.
2. `build-uefi.sh` invokes Project Mu for zorn models 0 and 1. The nested UEFI
   projects are supplied by the manifest, not by the broken old submodule URL.
3. `build-rootfs.sh` invokes the common_rootfs package/AUR assembly and makes
   an ext4 `rootfs.img`. `--prebuilt` supplies userspace binaries whose source
   is not currently present in the component repositories.
4. `build-esp.sh` compiles the selected DTS files, creates an ARM64 GRUB
   `BOOTAA64.EFI`, and creates a FAT32 `ESP.img` containing `/Image`, `/dtb`,
   and the current zorn GRUB menu.

## Required userspace artifacts

The current public source split does not yet contain source for every binary
that the device services reference, notably `rmtfs`, the production Mink
daemon, and several zorn helper daemons. The builder therefore accepts a
rootfs-shaped artifact directory instead of copying binaries from the device:

```text
prebuilt/
└── usr/
    ├── local/sbin/       zorn daemons, rmtfs, pd-mapper, tqftpserv, ...
    ├── local/lib/zorn/   qcomtee.ko
    └── lib/              optional packaged runtime libraries
```

The rootfs stage fails if a requested artifact directory is missing; it never
silently produces an image with unresolved service `ExecStart` paths.
