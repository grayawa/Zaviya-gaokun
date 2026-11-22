#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

KERNEL_REPOSITORY="${KERNEL_REPOSITORY:-grayawa/gaokun3-kernel-radxa-remix}"
KERNEL_COMMIT="${KERNEL_COMMIT:-5b35961926519b845cb919c94e275679d7e42f69}"
FIRMWARE_REPOSITORY="${FIRMWARE_REPOSITORY:-grayawa/gaokun-aosc-build}"
FIRMWARE_COMMIT="${FIRMWARE_COMMIT:-388959c6af8b51145f6667b1599da59533301b8d}"
WORK="${WORK:-${REPO_ROOT}/gaokun3-work/kernel-gaokun3}"
SRC="${KERNEL_SRC:-${WORK}/src}"
FW_SRC="${FIRMWARE_SRC:-${WORK}/firmware-src}"
OUT="${KERNEL_BUILD_DIR:-${WORK}/build}"
OUT_BASE="${OUT_BASE:-${WORK}/output}"
LOCALVERSION="${LOCALVERSION:--gaokun3-steamos}"
JOBS="${JOBS:-$(nproc)}"
ARCH=arm64

if [[ -z "${CROSS_COMPILE:-}" && "$(uname -m)" != "aarch64" ]]; then
    CROSS_COMPILE=aarch64-linux-gnu-
fi
CROSS_COMPILE="${CROSS_COMPILE:-}"
export ARCH CROSS_COMPILE

log() { printf '[gaokun3-kernel] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

check_deps() {
    local missing=() cmd
    for cmd in git make bc bison flex python3 perl rsync depmod; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ -n "$CROSS_COMPILE" ]]; then
        command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || missing+=("${CROSS_COMPILE}gcc")
    else
        command -v gcc >/dev/null 2>&1 || missing+=(gcc)
    fi
    [[ -f /usr/include/openssl/ssl.h ]] || missing+=(libssl-dev)
    [[ -f /usr/include/gelf.h ]] || missing+=(libelf-dev)
    if ((${#missing[@]})); then
        die "missing build dependencies: ${missing[*]} (install build-essential bc bison flex libssl-dev libelf-dev dwarves python3 git rsync kmod)"
    fi
}

fetch_pinned_repo() {
    local repository="$1" commit="$2" destination="$3"
    if [[ -d "${destination}/.git" ]]; then
        local actual
        actual="$(git -C "$destination" rev-parse HEAD)"
        [[ "$actual" == "$commit" ]] || die "$destination is at $actual, expected $commit; use a fresh WORK directory"
        [[ -z "$(git -C "$destination" status --porcelain --untracked-files=normal)" ]] \
            || die "$destination has local modifications; use a clean source checkout"
        return 0
    fi

    [[ ! -e "$destination" ]] || die "$destination exists but is not a Git checkout; remove it or set a different source path"
    mkdir -p "$(dirname "$destination")"
    log "fetch ${repository}@${commit}"
    git init -q "$destination"
    git -C "$destination" remote add origin "https://github.com/${repository}.git"
    git -C "$destination" fetch --depth=1 origin "$commit"
    git -C "$destination" checkout --detach FETCH_HEAD
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] || die "Git did not check out the requested commit for $repository"
}

apply_config_fragment() {
    local config="$1" fragment="$2" line option value
    local config_tool="${SRC}/scripts/config"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == CONFIG_*=* ]] || die "invalid config fragment line: $line"
        option="${line%%=*}"
        value="${line#*=}"
        option="${option#CONFIG_}"
        if [[ "$value" == \"*\" ]]; then
            value="${value:1:${#value}-2}"
            "$config_tool" --file "$config" --keep-case --set-str "$option" "$value"
        else
            case "$value" in
                y) "$config_tool" --file "$config" --keep-case --enable "$option" ;;
                m) "$config_tool" --file "$config" --keep-case --module "$option" ;;
                n) "$config_tool" --file "$config" --keep-case --disable "$option" ;;
                *) "$config_tool" --file "$config" --keep-case --set-val "$option" "$value" ;;
            esac
        fi
    done < "$fragment"
}

assert_config() {
    local expected="$1"
    grep -Fqx "$expected" "$OUT/.config" || die "required kernel option missing after olddefconfig: $expected"
}

main() {
    check_deps
    mkdir -p "$WORK" "$OUT_BASE"
    fetch_pinned_repo "$KERNEL_REPOSITORY" "$KERNEL_COMMIT" "$SRC"
    fetch_pinned_repo "$FIRMWARE_REPOSITORY" "$FIRMWARE_COMMIT" "$FW_SRC"

    [[ -f "$SRC/arch/arm64/configs/gaokun3_defconfig" ]] || die "pinned kernel source has no gaokun3_defconfig"
    [[ -f "$SRC/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts" ]] || die "pinned kernel source has no Gaokun3 DTS"
    [[ -d "$FW_SRC/firmware" ]] || die "pinned firmware source has no firmware directory"
    [[ -f "$REPO_ROOT/external-and-mods/kernel-common/steamos.config" ]] || die "missing shared SteamOS kernel config"

    rm -rf "$OUT"
    mkdir -p "$OUT"
    log "configure Linux $(sed -n 's/^VERSION = //p' "$SRC/Makefile").$(sed -n 's/^PATCHLEVEL = //p' "$SRC/Makefile").$(sed -n 's/^SUBLEVEL = //p' "$SRC/Makefile")"
    make -C "$SRC" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig

    local config_tool="${SRC}/scripts/config"
    "$config_tool" --file "$OUT/.config" --keep-case --set-str LOCALVERSION "$LOCALVERSION"
    "$config_tool" --file "$OUT/.config" --keep-case --disable LOCALVERSION_AUTO
    # Zaviya images boot through UEFI/systemd-boot, not OpenABL/Android ABL.
    "$config_tool" --file "$OUT/.config" --keep-case --enable EFI
    "$config_tool" --file "$OUT/.config" --keep-case --enable EFI_STUB
    apply_config_fragment "$OUT/.config" "$REPO_ROOT/external-and-mods/kernel-common/steamos.config"
    # Lepton in the Steam Frame userspace expects the binderfs device names below.
    "$config_tool" --file "$OUT/.config" --keep-case --enable ANDROID_BINDER_IPC
    "$config_tool" --file "$OUT/.config" --keep-case --enable ANDROID_BINDERFS
    "$config_tool" --file "$OUT/.config" --keep-case --set-str ANDROID_BINDER_DEVICES "anbox-binder,anbox-hwbinder,anbox-vndbinder"

    make -C "$SRC" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

    assert_config 'CONFIG_KPROBES=y'
    assert_config 'CONFIG_FTRACE=y'
    assert_config 'CONFIG_KPROBE_EVENTS=y'
    assert_config 'CONFIG_TRACING=y'
    assert_config 'CONFIG_TRACEFS_FS=y'
    assert_config 'CONFIG_EFI=y'
    assert_config 'CONFIG_EFI_STUB=y'
    assert_config 'CONFIG_ANDROID_BINDER_IPC=y'
    assert_config 'CONFIG_ANDROID_BINDERFS=y'
    assert_config 'CONFIG_ANDROID_BINDER_DEVICES="anbox-binder,anbox-hwbinder,anbox-vndbinder"'

    log "build Image, modules and Gaokun3 DTBs with ${JOBS} jobs"
    make -C "$SRC" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image modules dtbs
    local krel
    krel="$(make -s -C "$SRC" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)"
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "kernel Image was not produced"
    [[ -s "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" ]] || die "standard Gaokun3 DTB was not produced"
    [[ -s "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb" ]] || die "EL2 overlay DTB was not produced"

    local destination="${OUT_BASE}/${krel}"
    local staging="${WORK}/modules-staging"
    rm -rf "$destination" "$staging"
    mkdir -p "$destination/boot" "$destination/modules" "$destination/firmware" \
        "$destination/dtbs/qcom" "$destination/device-assets"

    log "install modules for ${krel}"
    make -C "$SRC" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        INSTALL_MOD_PATH="$staging" INSTALL_MOD_STRIP=1 modules_install
    depmod -b "$staging" "$krel"
    mv "$staging/lib/modules/$krel" "$destination/modules/$krel"
    rm -rf "$staging"

    cp "$OUT/arch/arm64/boot/Image" "$destination/boot/Image"
    ln "$destination/boot/Image" "$destination/boot/vmlinuz-${krel}"
    cp "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" "$destination/dtbs/qcom/"
    cp "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb" "$destination/dtbs/qcom/"
    cp -a "$FW_SRC/firmware/." "$destination/firmware/"
    cp -a "$FW_SRC/tools/audio" "$destination/device-assets/"
    cp -a "$FW_SRC/tools/bluetooth" "$destination/device-assets/"
    cp -a "$FW_SRC/tools/image-assets/etc" "$destination/device-assets/"
    cp "$OUT/.config" "$destination/config-${krel}"
    cp "$OUT/System.map" "$destination/System.map-${krel}"

    cat > "$destination/build-info.txt" <<INFO
kernel_repository=${KERNEL_REPOSITORY}
kernel_commit=${KERNEL_COMMIT}
firmware_repository=${FIRMWARE_REPOSITORY}
firmware_commit=${FIRMWARE_COMMIT}
kernel_release=${krel}
localversion=${LOCALVERSION}
boot_format=arm64 Image with EFI stub; systemd-boot + external DTB
INFO
    printf '%s\n' "$krel" > "${OUT_BASE}/kernel-release.txt"
    ln -sfn "$krel" "${OUT_BASE}/current"
    log "done: $destination"
}

main "$@"
