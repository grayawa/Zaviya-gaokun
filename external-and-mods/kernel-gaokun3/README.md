# Gaokun3 kernel integration

This directory is the first device-porting layer for the Huawei MateBook E Go
2022 Performance Edition (Gaokun3, Qualcomm SC8280XP / Adreno 690).

It deliberately builds a UEFI-loadable ARM64 kernel rather than reusing the
existing ROCKNIX/OpenABL ABL boot-image path. Gaokun3 is intended to boot from
its Qualcomm UEFI firmware through an EFI system partition and systemd-boot.

## Pinned inputs

- Kernel: grayawa/gaokun3-kernel-radxa-remix
  - Branch: 7.2.15-bore
  - Commit: 5b35961926519b845cb919c94e275679d7e42f69
- Device firmware and userspace assets: grayawa/gaokun-aosc-build
  - Branch at pin time: next
  - Commit: 388959c6af8b51145f6667b1599da59533301b8d

Both inputs are pinned by commit in build.sh. The firmware repository is used
as the existing source of Gaokun3 DSP, Wi-Fi/Bluetooth, audio-topology and
device configuration assets; this recipe does not invent replacement blobs.

## Kernel configuration

The build starts from the pinned source tree's gaokun3_defconfig and applies
the shared SteamOS fragment from kernel-common/steamos.config.

The recipe additionally:

- enables EFI and EFI stub support for systemd-boot;
- sets the binderfs device names expected by the Steam Frame userspace;
- verifies KPROBES, FTRACE, KPROBE_EVENTS, TRACING and TRACEFS_FS remain enabled
  after olddefconfig.

The pinned gaokun3_defconfig already contains all five tracing/kprobe options.
No duplicate kernel patch is carried here.

## Build

On an ARM64 Linux host:

~~~bash
sudo apt-get install build-essential bc bison flex libssl-dev libelf-dev \
  dwarves python3 git rsync kmod
bash external-and-mods/kernel-gaokun3/build.sh
~~~

The build can also cross-compile from x86_64 when an aarch64 GNU toolchain is
installed. Set CROSS_COMPILE=aarch64-linux-gnu- in that case.

The WORK environment variable controls the work and output directory. The
GitHub Actions workflow builds the same recipe on an ARM64 runner and uploads
the resulting kernel artifact.

## Output layout

The output directory is output/<kernel-release>/ and contains:

- boot/Image and boot/vmlinuz-<kernel-release>: the EFI-stub kernel image;
- dtbs/qcom/sc8280xp-huawei-gaokun3.dtb: the normal Gaokun3 device tree;
- dtbs/qcom/sc8280xp-huawei-gaokun3-el2.dtb: the source tree's EL2 overlay DTB;
- modules/<kernel-release>: installed kernel modules;
- firmware/: the pinned Gaokun3 firmware tree;
- device-assets/: audio, Bluetooth and selected system configuration assets;
- config-<kernel-release> and System.map-<kernel-release>.

The EL2 DTB is staged for inspection only. It is not the default boot DTB, and
this recipe does not claim that an EL2 kernel/boot chain has been validated.

## Current boundary

This is a kernel build milestone, not yet a flashable Zaviya image. It does
not install the kernel into the Steam Frame rootfs or create an EFI disk image.

Remaining integration work includes the Gaokun3 rootfs overlay, systemd-boot
image assembly, Adreno 690 Mesa/Turnip validation, portrait display setup,
audio UCM/WirePlumber integration, input and power-management configuration,
and real-device boot testing. In particular, the Steam Frame's stock Adreno
750 userspace must not be assumed to work unchanged on Adreno 690.
