#!/bin/bash
set -euo pipefail

# Flash directly from the current Linux machine. Use this when the CHIP/PocketCHIP
# USB cable is plugged into the same PC running this script.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

TOOLS_DIR=${TOOLS_DIR:-${FLASH_TOOLS_DIR:-../x-chip-tools}}
ROOTFS=${ROOTFS:-$OUT}
DO_FLASH=0

usage() {
    cat <<EOF
usage: $0 [--flash] [--tools-dir ../x-chip-tools] [--rootfs $OUT]

Default mode runs local preflight checks only.
Use --flash to actually erase/write the PocketCHIP NAND via flash-live.sh.

Environment overrides:
  TOOLS_DIR       x-chip-tools path on this machine (default: ../x-chip-tools)
  FLASH_TOOLS_DIR alias for TOOLS_DIR
  ROOTFS          local rootfs tar to flash (default: $OUT)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --flash)
            DO_FLASH=1
            ;;
        --tools-dir)
            TOOLS_DIR=${2:?missing value for --tools-dir}
            shift
            ;;
        --rootfs)
            ROOTFS=${2:?missing value for --rootfs}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

[ -f "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS" >&2; exit 1; }
ROOTFS=$(cd "$(dirname "$ROOTFS")" && pwd)/$(basename "$ROOTFS")

ensure_x_chip_tools() {
    local dest=$1
    if [ -f "$dest/flash-live.sh" ]; then
        return 0
    fi
    if [ -e "$dest" ] && [ -n "$(find "$dest" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
        echo "ERROR: $dest exists but is not x-chip-tools" >&2
        exit 1
    fi
    command -v git >/dev/null || { echo "need git to clone x-chip-tools" >&2; exit 1; }
    echo ">> cloning x-chip-tools"
    git clone https://github.com/nextthingco/x-chip-tools.git "$dest"
}

ensure_x_chip_tools "$TOOLS_DIR"
TOOLS_DIR=$(cd "$TOOLS_DIR" && pwd)
export PATH="$TOOLS_DIR/sunxi-tools:$HERE/result/bin:$PATH"

require_cmd() {
    command -v "$1" >/dev/null || {
        echo "missing command: $1" >&2
        exit 1
    }
}

require_file() {
    [ -f "$1" ] || {
        echo "missing file: $1" >&2
        exit 1
    }
}

download_latest_asset() {
    local repo=$1 pattern=$2 dest=$3 tag url name
    [ -f "$dest" ] && return 0
    mkdir -p "$(dirname "$dest")"

    echo ">> downloading missing $pattern from $repo"
    tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$tag" ] || { echo "could not resolve latest release for $repo" >&2; exit 1; }

    url=$(
        curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$tag" \
        | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | while IFS= read -r candidate; do
            name=${candidate##*/}
            case "$name" in
                $pattern) printf '%s\n' "$candidate"; break ;;
            esac
        done
    )
    [ -n "$url" ] || { echo "could not find $pattern in $repo release $tag" >&2; exit 1; }
    curl -fL -o "$dest" "$url"
}

echo ">> local tools: $TOOLS_DIR"
echo ">> local rootfs: $ROOTFS"
echo ">> local sha256: $(sha256sum "$ROOTFS" | awk '{print $1}')"

for cmd in sha256sum tar ssh ping dd mkimage sunxi-fel sunxi-nand-image-builder curl; do
    require_cmd "$cmd"
done
sudo -n true

cd "$TOOLS_DIR"
download_latest_asset nextthingco/x-chip-tools initrd.uimage .images/initrd.uimage
download_latest_asset nextthingco/x-chip-uboot sunxi-spl.bin .images/uboot/sunxi-spl.bin
download_latest_asset nextthingco/x-chip-uboot u-boot-dtb.bin .images/uboot/u-boot-dtb.bin
download_latest_asset nextthingco/x-chip-uboot u-boot-sunxi-with-spl.bin .images/uboot/u-boot-sunxi-with-spl.bin
download_latest_asset nextthingco/x-chip-os pocketchip-rootfs.tar.gz .images/pocketchip-rootfs.tar.gz

require_file ".images/initrd.uimage"
require_file ".images/uboot/u-boot-sunxi-with-spl.bin"
require_file ".images/uboot/sunxi-spl.bin"
require_file ".images/uboot/u-boot-dtb.bin"
require_file ".images/pocketchip-rootfs.tar.gz"
require_file "flash-live.sh"

echo ">> extracting known-good installer kernel"
rm -rf /tmp/x-chip-installer-kernel
mkdir -p /tmp/x-chip-installer-kernel
tar -C /tmp/x-chip-installer-kernel -xzf .images/pocketchip-rootfs.tar.gz \
    --wildcards './boot/vmlinuz-*-chip' './boot/dtbs/*/sun5i-r8-chip.dtb'

ZIMAGE=$(ls -1 /tmp/x-chip-installer-kernel/boot/vmlinuz-*-chip | head -n1)
DTB=$(find /tmp/x-chip-installer-kernel/boot/dtbs -name sun5i-r8-chip.dtb | head -n1)
[ -n "$ZIMAGE" ] || { echo "installer zImage not found" >&2; exit 1; }
[ -n "$DTB" ] || { echo "installer dtb not found" >&2; exit 1; }

echo ">> installer zImage: $ZIMAGE"
echo ">> installer dtb: $DTB"

if [ "$DO_FLASH" != 1 ]; then
    echo ">> preflight complete"
    echo ">> connect PocketCHIP/CHIP in FEL mode, then rerun with --flash"
    exit 0
fi

verify_flashed_rootfs() {
    local key=assets/installer_key
    local ssh_cmd=(ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.81.1)
    require_file "$key"
    chmod og-rw "$key"

    echo ">> verifying flashed rootfs"
    "${ssh_cmd[@]}" 'sh -seu' <<'INNER'
cleanup() {
  umount /verify-rootfs 2>/dev/null || true
  ubidetach -m 4 2>/dev/null || true
}
trap cleanup EXIT

ubidetach -m 4 2>/dev/null || true
ubiattach -m 4
mkdir -p /verify-rootfs
mount -t ubifs -o ro /dev/ubi0_0 /verify-rootfs

ls -l /verify-rootfs/boot/zImage /verify-rootfs/boot/boot.scr /verify-rootfs/boot/sun5i-r8-chip.dtb
test -u /verify-rootfs/bin/busybox.suid
test -u /verify-rootfs/usr/bin/sudo
test "$(stat -c '%u:%g' /verify-rootfs/bin/busybox.suid)" = "0:0"
test "$(stat -c '%u:%g' /verify-rootfs/usr/bin/sudo)" = "0:0"
test "$(stat -c '%u:%g' /verify-rootfs/etc/shadow)" = "0:0"
test "$(stat -c '%a' /verify-rootfs/etc/shadow)" = "600"
test "$(stat -c '%u:%g' /verify-rootfs/home/chip)" = "1000:1000"
test "$(stat -c '%u:%g' /verify-rootfs/home/chip/.ssh/authorized_keys)" = "1000:1000"
test "$(stat -c '%a' /verify-rootfs/home/chip/.ssh)" = "700"
test "$(stat -c '%a' /verify-rootfs/home/chip/.ssh/authorized_keys)" = "600"
for node in /dev/console /dev/null /dev/tty /dev/tty0 /dev/tty1 /dev/ttyS0 /dev/net/tun; do
  test -c "/verify-rootfs$node"
  test "$(stat -c '%u:%g' "/verify-rootfs$node")" = "0:0"
done
grep -q 'PocketCHIP TinyCore' /verify-rootfs/etc/os-release
grep -q 'udevadm settle --timeout=5' /verify-rootfs/etc/init.d/tc-config
grep -q 'fstab_pid:-' /verify-rootfs/etc/init.d/tc-config
grep -q 'WAITED' /verify-rootfs/opt/x-chip-tty1-getty.sh
grep -q '192.168.82.1' /verify-rootfs/opt/x-chip-firstboot.sh
grep -q 'start_usb_debug_gadget' /verify-rootfs/opt/x-chip-firstboot.sh
grep -q 'load_tcz_boot_core' /verify-rootfs/opt/x-chip-firstboot.sh
grep -q 'load_tcz_onboot_background' /verify-rootfs/opt/x-chip-firstboot.sh
grep -q 'start_ssh' /verify-rootfs/opt/x-chip-firstboot.sh
grep -q 'UseDNS no' /verify-rootfs/usr/local/etc/ssh/sshd_config
if grep -q 'UsePAM' /verify-rootfs/usr/local/etc/ssh/sshd_config; then
  echo "ERROR: sshd_config contains unsupported UsePAM option" >&2
  exit 1
fi
test -s /verify-rootfs/usr/share/kmap/pocketchip.kmap
test "$(od -An -tx1 -j264 -N16 /verify-rootfs/usr/share/kmap/pocketchip.kmap | tr -d ' \n')" = "021b0031003200330034003500360037"
test "$(od -An -tx1 -j816 -N10 /verify-rootfs/usr/share/kmap/pocketchip.kmap | tr -d ' \n')" = "0b7b007d005b005d007c"
test -s /verify-rootfs/lib/firmware/rtlwifi/rtl8723bs_nic.bin
find /verify-rootfs/lib/modules -path '*/extra/8812au.ko' -type f | grep -q . || echo "WARN: RTL8812AU module not present"
grep -a -q 'video=Unknown-1:480x272e' /verify-rootfs/boot/boot.scr
grep -a -q 'video=Composite-1:d' /verify-rootfs/boot/boot.scr
grep -a -q 'tce=/tce base' /verify-rootfs/boot/boot.scr
grep -a -q 'x-chip-pocketchip.dtbo' /verify-rootfs/boot/boot.scr
test -f /verify-rootfs/lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo
test -f /verify-rootfs/tce/xorg.lst
grep -q 'Xorg.tcz' /verify-rootfs/tce/xorg.lst
grep -q 'xf86-video-fbdev.tcz' /verify-rootfs/tce/xorg.lst
if grep -q '^xf86-video-fbturbo.tcz' /verify-rootfs/tce/xorg.lst; then
  echo "ERROR: fbturbo must stay disabled; use fbdev for the current Xorg ABI" >&2
  exit 1
fi
grep -q 'flwm.tcz' /verify-rootfs/tce/xorg.lst
grep -q 'jwm.tcz' /verify-rootfs/tce/xorg.lst
grep -q 'aterm.tcz' /verify-rootfs/tce/xorg.lst
test -x /verify-rootfs/usr/local/bin/x-chip-startx
grep -q 'Driver "fbdev"' /verify-rootfs/usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf
grep -q 'Driver "fbturbo"' /verify-rootfs/usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example
if grep -q 'Xorg.tcz' /verify-rootfs/tce/onboot.lst; then
  echo "ERROR: Xorg must not be in onboot.lst" >&2
  exit 1
fi
test -e /verify-rootfs/home/chip/.ssh/authorized_keys || echo "WARN: no authorized_keys file; public image needs manual SSH key setup"
test -f /verify-rootfs/etc/wpa_supplicant.conf || echo "WARN: no WiFi config; use serial/LCD/USB debug until configured"
grep 'PRETTY_NAME' /verify-rootfs/etc/os-release
INNER
}

echo ">> checking FEL"
sudo -n env PATH="$PATH" sunxi-fel ver

echo ">> flashing TinyCore rootfs"
sudo -n env PATH="$PATH" \
    ZIMAGE="$ZIMAGE" \
    DTB="$DTB" \
    UBOOT="$TOOLS_DIR/.images/uboot/u-boot-sunxi-with-spl.bin" \
    SPL="$TOOLS_DIR/.images/uboot/sunxi-spl.bin" \
    UBOOT_BIN="$TOOLS_DIR/.images/uboot/u-boot-dtb.bin" \
    INITRD="$TOOLS_DIR/.images/initrd.uimage" \
    "$TOOLS_DIR/flash-live.sh" "$ROOTFS"
verify_flashed_rootfs
echo ">> flash complete -- remove the FEL jumper and power-cycle into NAND"
