#!/bin/bash -e

# Build a sun5i / Cortex-A8-optimized mainline kernel for the CHIP and install
# it into build/rootfs: zImage + dtb in /boot, modules in /lib/modules.
# Starts from the kernel's Allwinner-only sunxi_defconfig (NOT Debian's
# multi-vendor armmp) and merges the CHIP fragment in kernel/sun5i-chip.config.

HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
source ./config.env

need_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [ "$1" = chown ]; then
        "$@" 2>/dev/null || true
    else
        "$@"
    fi
}
resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$HERE/$1" ;;
    esac
}

[ -d build/rootfs ] || { echo "run 'make base' first (build/rootfs missing)" >&2; exit 1; }
for required in bin/busybox sbin/init init etc/inittab etc/init.d/tc-config; do
    [ -e "build/rootfs/$required" ] || {
        echo "ERROR: build/rootfs is not a complete CorePure rootfs; missing /$required" >&2
        echo "Run 'make base' again before building the kernel." >&2
        exit 1
    }
done

cd build
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
SRC="linux-${KERNEL_VERSION}"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" \
    "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${TARBALL}"
[ -d "$SRC" ] || tar xf "$TARBALL"
cd "$SRC"

# CHIP board fixes (reused from chip-debroot). The Hynix-NAND patch is a no-op
# on >= 5.16 so it is skipped; apply the DRM color + i2c-shutdown fixes,
# tolerating an already-patched tree.
PATCHDIR=$(resolve_path "$CHIP_KERNEL_PATCHES")
for p in "$PATCHDIR"/0001-drm-*.patch "$PATCHDIR"/0001-i2c-*.patch; do
    [ -f "$p" ] || continue
    if patch -p1 -N --dry-run <"$p" >/dev/null 2>&1; then
        patch -p1 -N <"$p"
    else
        echo ">> skip (already applied or N/A): $(basename "$p")"
    fi
done

export ARCH CROSS_COMPILE
make sunxi_defconfig
./scripts/kconfig/merge_config.sh -m .config "$HERE/kernel/sun5i-chip.config"
make olddefconfig
make LOCALVERSION="$KERNEL_LOCALVERSION" DTC_FLAGS="-@" -j"$(nproc)" zImage dtbs modules

KREL=$(make -s LOCALVERSION="$KERNEL_LOCALVERSION" kernelrelease)
echo ">> built kernel: $KREL"

RFS="$HERE/build/rootfs"
need_root install -d "$RFS/boot"
need_root install -m644 arch/arm/boot/zImage "$RFS/boot/zImage"
need_root install -m644 arch/arm/boot/zImage "$RFS/boot/vmlinuz-$KREL"

# dtb path moved under allwinner/ in >= 6.5; handle both.
if [ -f "arch/arm/boot/dts/allwinner/$DTB" ]; then
    DTB_SRC="arch/arm/boot/dts/allwinner/$DTB"
else
    DTB_SRC="arch/arm/boot/dts/$DTB"
fi

CUSTOM_DTB_DTS="$HERE/kernel/sun5i-r8-chip-tinycore.dts"
DTB_TMP_DTS=
DTB_TMP_DTB=
if [ -f "$CUSTOM_DTB_DTS" ]; then
    echo ">> compiling TinyCore CHIP DTB with NAND partitions"
    DTB_TMP_DTS=$(mktemp)
    DTB_TMP_DTB=$(mktemp)
    cpp -nostdinc -undef -x assembler-with-cpp \
        -I include \
        -I arch/arm/boot/dts \
        -I arch/arm/boot/dts/allwinner \
        "$CUSTOM_DTB_DTS" >"$DTB_TMP_DTS"
    ./scripts/dtc/dtc -@ -I dts -O dtb -o "$DTB_TMP_DTB" "$DTB_TMP_DTS"
    DTB_SRC="$DTB_TMP_DTB"
fi
need_root install -m644 "$DTB_SRC" "$RFS/boot/$DTB"
need_root install -d "$RFS/boot/dtbs/$KREL"
need_root install -m644 "$DTB_SRC" "$RFS/boot/dtbs/$KREL/$DTB"

# x-chip-tools/flash-live.sh extracts Debian-style names from the tar to boot
# its installer. Provide aliases so it can use this TinyCore kernel unchanged.
FLASH_KREL="${KERNEL_VERSION}-chip"
if [ "$FLASH_KREL" != "$KREL" ]; then
    need_root install -m644 arch/arm/boot/zImage "$RFS/boot/vmlinuz-$FLASH_KREL"
    need_root install -d "$RFS/boot/dtbs/$FLASH_KREL"
    need_root install -m644 "$DTB_SRC" "$RFS/boot/dtbs/$FLASH_KREL/$DTB"
fi

[ -n "$DTB_TMP_DTS" ] && rm -f "$DTB_TMP_DTS"
[ -n "$DTB_TMP_DTB" ] && rm -f "$DTB_TMP_DTB"

compile_overlay() {
    local src=$1 out=$2 tmp dtbo
    [ -f "$src" ] || return 0
    command -v cpp >/dev/null || { echo "need cpp to compile DT overlays" >&2; exit 1; }
    tmp=$(mktemp)
    dtbo=$(mktemp)
    cpp -nostdinc -undef -x assembler-with-cpp \
        -I include \
        -I arch/arm/boot/dts \
        -I arch/arm/boot/dts/allwinner \
        -I "$OVERLAY_DIR" \
        "$src" >"$tmp"
    ./scripts/dtc/dtc -@ -I dts -O dtb -o "$dtbo" "$tmp"
    need_root install -m644 "$dtbo" "$RFS/lib/firmware/nextthingco/chip/early/$out"
    rm -f "$tmp" "$dtbo"
}

materialize_lib_firmware() {
    local current_target=
    if [ -L "$RFS/lib/firmware" ]; then
        current_target=$(readlink -f "$RFS/lib/firmware" 2>/dev/null || true)
        need_root rm -f "$RFS/lib/firmware"
        need_root install -d "$RFS/lib/firmware"
        if [ -n "$current_target" ] && [ -d "$current_target" ]; then
            need_root cp -a "$current_target/." "$RFS/lib/firmware/"
        fi
    fi
}

OVERLAY_DIR=$(resolve_path "$CHIP_DTS_DIR")
if [ -d "$OVERLAY_DIR" ]; then
    materialize_lib_firmware
    need_root install -d "$RFS/lib/firmware/nextthingco/chip/early"
    compile_overlay "$OVERLAY_DIR/dip-9d011a-1.dts" x-chip-pocketchip.dtbo
    compile_overlay "$OVERLAY_DIR/dip-9d011a-2.dts" x-chip-dip-vga.dtbo
    compile_overlay "$OVERLAY_DIR/dip-9d011a-3.dts" x-chip-dip-hdmi.dtbo
fi

need_root make ARCH=arm INSTALL_MOD_PATH="$RFS" modules_install

echo ">> kernel $KREL + modules installed into build/rootfs"
