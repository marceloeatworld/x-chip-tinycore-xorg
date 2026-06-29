#!/bin/bash
set -euo pipefail

# Copy the TinyCore rootfs to a Linux USB/FEL host over SSH, then run the live
# flasher with the known-good cached PocketCHIP kernel as installer kernel.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

FLASH_HOST=${FLASH_HOST:-${PI_HOST:-}}
FLASH_TOOLS_DIR=${FLASH_TOOLS_DIR:-${PI_TOOLS_DIR:-x-chip-tools}}
ROOTFS=${ROOTFS:-$OUT}
REMOTE_ROOTFS=${REMOTE_ROOTFS:-tinycore-rootfs.tar.gz}
SSH_CONFIG=${SSH_CONFIG:-${HOME:-}/.ssh/config}
DO_FLASH=0
COPY_ROOTFS=1
REUSE_INSTALLER=0

usage() {
    cat <<EOF
usage: $0 [--flash] [--reuse-installer] [--no-copy] --host <linux-host> [--tools-dir x-chip-tools] [--rootfs $OUT]

Default mode copies the rootfs to the SSH flashing host and runs preflight checks only.
Use --flash to actually erase/write the PocketCHIP NAND via flash-live.sh.
Use --reuse-installer with --flash when CHIP-installer is already running on
USB-net; this rewrites only the rootfs volume and skips FEL/SPL/U-Boot loading.

Environment overrides:
  FLASH_HOST      SSH host for the USB/FEL flashing machine
  FLASH_TOOLS_DIR x-chip-tools path on the flashing host, relative to SSH home unless absolute (default: x-chip-tools)
  PI_HOST         Backward-compatible alias for FLASH_HOST
  PI_TOOLS_DIR    Backward-compatible alias for FLASH_TOOLS_DIR
  ROOTFS          local rootfs tar to flash (default: $OUT)
  REMOTE_ROOTFS   remote filename under FLASH_TOOLS_DIR (default: tinycore-rootfs.tar.gz)
  SSH_CONFIG      SSH config for the host connection (default: \$HOME/.ssh/config, if present)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --flash)
            DO_FLASH=1
            ;;
        --reuse-installer)
            REUSE_INSTALLER=1
            ;;
        --no-copy)
            COPY_ROOTFS=0
            ;;
        --host)
            FLASH_HOST=${2:?missing value for --host}
            shift
            ;;
        --tools-dir)
            FLASH_TOOLS_DIR=${2:?missing value for --tools-dir}
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

[ -n "$FLASH_HOST" ] || {
    echo "missing flash host; pass --host <linux-host> or set FLASH_HOST" >&2
    usage >&2
    exit 2
}
[ -f "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS" >&2; exit 1; }
command -v ssh >/dev/null || { echo "need ssh" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "need sha256sum" >&2; exit 1; }

LOCAL_SHA=$(sha256sum "$ROOTFS" | awk '{print $1}')
SSH_OPTS=(-o ControlMaster=no -o ControlPath=none)
if [ -f "$SSH_CONFIG" ]; then
    SSH_OPTS=(-F "$SSH_CONFIG" -o ControlMaster=no -o ControlPath=none)
fi

shq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_env() {
    printf 'FLASH_TOOLS_DIR=%s REMOTE_ROOTFS=%s EXPECTED_SHA=%s DO_FLASH=%s REUSE_INSTALLER=%s X_CHIP_TOOLS_RELEASE_TAG=%s X_CHIP_UBOOT_RELEASE_TAG=%s X_CHIP_OS_RELEASE_TAG=%s X_CHIP_INITRD_SHA256=%s X_CHIP_SPL_SHA256=%s X_CHIP_UBOOT_DTB_SHA256=%s X_CHIP_UBOOT_WITH_SPL_SHA256=%s X_CHIP_POCKETCHIP_ROOTFS_SHA256=%s' \
        "$(shq "$FLASH_TOOLS_DIR")" \
        "$(shq "$REMOTE_ROOTFS")" \
        "$(shq "$LOCAL_SHA")" \
        "$(shq "$DO_FLASH")" \
        "$(shq "$REUSE_INSTALLER")" \
        "$(shq "${X_CHIP_TOOLS_RELEASE_TAG:-}")" \
        "$(shq "${X_CHIP_UBOOT_RELEASE_TAG:-}")" \
        "$(shq "${X_CHIP_OS_RELEASE_TAG:-}")" \
        "$(shq "${X_CHIP_INITRD_SHA256:-}")" \
        "$(shq "${X_CHIP_SPL_SHA256:-}")" \
        "$(shq "${X_CHIP_UBOOT_DTB_SHA256:-}")" \
        "$(shq "${X_CHIP_UBOOT_WITH_SPL_SHA256:-}")" \
        "$(shq "${X_CHIP_POCKETCHIP_ROOTFS_SHA256:-}")"
}

echo ">> flash host: $FLASH_HOST"
echo ">> host tools: $FLASH_TOOLS_DIR"
echo ">> local rootfs: $ROOTFS"
echo ">> local sha256: $LOCAL_SHA"

ssh "${SSH_OPTS[@]}" "$FLASH_HOST" "$(remote_env) bash -s" <<'REMOTE'
set -euo pipefail
sudo -n true
if [ ! -f "$FLASH_TOOLS_DIR/flash-live.sh" ]; then
    if [ -e "$FLASH_TOOLS_DIR" ] && [ -n "$(find "$FLASH_TOOLS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
        echo "ERROR: $FLASH_TOOLS_DIR exists but is not x-chip-tools" >&2
        exit 1
    fi
    command -v git >/dev/null || { echo "missing command on flash host: git" >&2; exit 1; }
    echo ">> cloning x-chip-tools on flash host"
    git clone https://github.com/nextthingco/x-chip-tools.git "$FLASH_TOOLS_DIR"
else
    mkdir -p "$FLASH_TOOLS_DIR"
fi
REMOTE

if [ "$COPY_ROOTFS" = 1 ]; then
    command -v scp >/dev/null || { echo "need scp" >&2; exit 1; }
    echo ">> copying rootfs to flash host"
    scp "${SSH_OPTS[@]}" "$ROOTFS" "$FLASH_HOST:$FLASH_TOOLS_DIR/$REMOTE_ROOTFS"
else
    echo ">> copy disabled; using existing flash-host rootfs"
fi

ssh "${SSH_OPTS[@]}" "$FLASH_HOST" "$(remote_env) bash -s" <<'REMOTE'
set -euo pipefail
cd "$FLASH_TOOLS_DIR"
FLASH_TOOLS_DIR=$(pwd)
export PATH="$FLASH_TOOLS_DIR/sunxi-tools:$PATH"

require_cmd() {
    command -v "$1" >/dev/null || {
        echo "missing command on flash host: $1" >&2
        exit 1
    }
}

require_file() {
    [ -f "$1" ] || {
        echo "missing file on flash host: $1" >&2
        exit 1
    }
}

verify_sha256() {
    local file=$1 expected=$2 actual
    [ -n "$expected" ] || return 0
    actual=$(sha256sum "$file" | awk '{ print $1 }')
    [ "$actual" = "$expected" ] || {
        echo "sha256 mismatch: $file" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

download_file() {
    local url=$1 dest=$2 expected_sha=${3:-} tmp
    tmp="$dest.part.$$"
    rm -f "$tmp"
    if curl -fL --remove-on-error -o "$tmp" "$url"; then
        [ -s "$tmp" ] || { echo "empty download: $url" >&2; rm -f "$tmp"; exit 1; }
        verify_sha256 "$tmp" "$expected_sha"
        mv -f "$tmp" "$dest"
    else
        rm -f "$tmp"
        exit 1
    fi
}

echo ">> preflight on $(hostname)"
sudo -n true

for cmd in sha256sum tar ssh ping ip dd mkimage sunxi-fel sunxi-nand-image-builder; do
    require_cmd "$cmd"
done
require_cmd curl

download_latest_asset() {
    local repo=$1 pattern=$2 dest=$3 tag=${4:-} expected_sha=${5:-} url name
    if [ -f "$dest" ]; then
        verify_sha256 "$dest" "$expected_sha"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"

    echo ">> downloading missing $pattern from $repo"
    if [ -z "$tag" ]; then
        tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    fi
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
    download_file "$url" "$dest" "$expected_sha"
}

require_file "$REMOTE_ROOTFS"
download_latest_asset nextthingco/x-chip-tools initrd.uimage .images/initrd.uimage "${X_CHIP_TOOLS_RELEASE_TAG:-}" "${X_CHIP_INITRD_SHA256:-}"
download_latest_asset nextthingco/x-chip-uboot sunxi-spl.bin .images/uboot/sunxi-spl.bin "${X_CHIP_UBOOT_RELEASE_TAG:-}" "${X_CHIP_SPL_SHA256:-}"
download_latest_asset nextthingco/x-chip-uboot u-boot-dtb.bin .images/uboot/u-boot-dtb.bin "${X_CHIP_UBOOT_RELEASE_TAG:-}" "${X_CHIP_UBOOT_DTB_SHA256:-}"
download_latest_asset nextthingco/x-chip-uboot u-boot-sunxi-with-spl.bin .images/uboot/u-boot-sunxi-with-spl.bin "${X_CHIP_UBOOT_RELEASE_TAG:-}" "${X_CHIP_UBOOT_WITH_SPL_SHA256:-}"
download_latest_asset nextthingco/x-chip-os pocketchip-rootfs.tar.gz .images/pocketchip-rootfs.tar.gz "${X_CHIP_OS_RELEASE_TAG:-}" "${X_CHIP_POCKETCHIP_ROOTFS_SHA256:-}"
require_file ".images/initrd.uimage"
require_file ".images/uboot/u-boot-sunxi-with-spl.bin"
require_file ".images/uboot/sunxi-spl.bin"
require_file ".images/uboot/u-boot-dtb.bin"
require_file ".images/pocketchip-rootfs.tar.gz"
require_file "flash-live.sh"

actual_sha=$(sha256sum "$REMOTE_ROOTFS" | awk '{print $1}')
echo ">> remote sha256: $actual_sha"
[ "$actual_sha" = "$EXPECTED_SHA" ] || {
    echo "rootfs sha256 mismatch" >&2
    exit 1
}

echo ">> extracting known-good installer kernel from cached PocketCHIP image"
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

bind_existing_installer() {
    echo ">> binding existing CHIP-installer USB network"
    sudo -n modprobe rndis_host || true
    for iface in /sys/bus/usb/devices/*:*; do
        [ -r "$iface/bInterfaceClass" ] || continue
        [ -r "$iface/modalias" ] || continue
        if grep -q 'v1F3ApEFE8' "$iface/modalias"; then
            name=${iface##*/}
            echo "$name" | sudo -n tee /sys/bus/usb/drivers/rndis_host/bind >/dev/null 2>&1 || true
        fi
    done

    local iface_name=
    for _ in $(seq 20); do
        for addr in /sys/class/net/*/address; do
            [ "$(cat "$addr" 2>/dev/null)" = "de:ad:be:ef:53:02" ] || continue
            iface_name=$(basename "$(dirname "$addr")")
            break
        done
        [ -n "$iface_name" ] && break
        sleep 1
    done
    [ -n "$iface_name" ] || { echo "existing installer USB NIC not found" >&2; exit 1; }
    sudo -n ip addr replace 192.168.81.2/24 dev "$iface_name"
    sudo -n ip link set "$iface_name" up
    ping -c1 -W2 192.168.81.1 >/dev/null
    echo ">> existing installer reachable on $iface_name"
}

install_rootfs_over_existing_installer() {
    local key=assets/installer_key
    local ssh="ssh -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.81.1"
    chmod og-rw "$key"

    echo ">> formatting SLC UBI rootfs volume"
    $ssh 'sh -seux' <<'INNER'
cat /proc/mtd
umount -l /rootfs 2>/dev/null || true
ubidetach -m 4 2>/dev/null || true
ubiformat /dev/mtd4 -y
ubiattach -m 4
ubimkvol /dev/ubi0 --name rootfs -m
mkfs.ubifs /dev/ubi0_0
mkdir -p /rootfs
mount -t ubifs /dev/ubi0_0 /rootfs
INNER

    $ssh "date -s @$(date +%s)" || true
    echo ">> streaming rootfs into UBIFS"
    dd if="$REMOTE_ROOTFS" bs=1M status=progress | $ssh "tar -C /rootfs -xzf -"

    echo ">> verifying + detaching UBI"
    $ssh 'sh -seux' <<'INNER'
ls -l /rootfs/boot/zImage /rootfs/boot/boot.scr /rootfs/boot/sun5i-r8-chip.dtb
test -u /rootfs/bin/busybox.suid
test -u /rootfs/usr/bin/sudo
test "$(stat -c '%u:%g' /rootfs/bin/busybox.suid)" = "0:0"
test "$(stat -c '%u:%g' /rootfs/usr/bin/sudo)" = "0:0"
test "$(stat -c '%u:%g' /rootfs/etc/shadow)" = "0:0"
test "$(stat -c '%a' /rootfs/etc/shadow)" = "600"
test "$(stat -c '%u:%g' /rootfs/home/chip)" = "1000:1000"
test "$(stat -c '%u:%g' /rootfs/home/chip/.ssh/authorized_keys)" = "1000:1000"
test "$(stat -c '%a' /rootfs/home/chip/.ssh)" = "700"
test "$(stat -c '%a' /rootfs/home/chip/.ssh/authorized_keys)" = "600"
for node in /dev/console /dev/null /dev/tty /dev/tty0 /dev/tty1 /dev/ttyS0 /dev/net/tun; do
  test -c "/rootfs$node"
  test "$(stat -c '%u:%g' "/rootfs$node")" = "0:0"
done
[ -x /rootfs/opt/x-chip-boot.sh ]
[ ! -e /rootfs/opt/x-chip-firstboot.sh ]
grep -q '192.168.82.1' /rootfs/opt/x-chip-boot.sh
grep -q 'start_usb_debug_gadget' /rootfs/opt/x-chip-boot.sh
grep -q 'start_ssh' /rootfs/opt/x-chip-boot.sh
grep -q 'UseDNS no' /rootfs/usr/local/etc/ssh/sshd_config
if grep -q 'UsePAM' /rootfs/usr/local/etc/ssh/sshd_config; then
  echo "ERROR: sshd_config contains unsupported UsePAM option" >&2
  exit 1
fi
grep -q 'PocketCHIP TinyCore' /rootfs/etc/os-release
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/tmp[[:space:]]+tmpfs[[:space:]]+' /rootfs/etc/fstab
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/run[[:space:]]+tmpfs[[:space:]]+' /rootfs/etc/fstab
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/var/run[[:space:]]+tmpfs[[:space:]]+' /rootfs/etc/fstab
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/var/lock[[:space:]]+tmpfs[[:space:]]+' /rootfs/etc/fstab
grep -q 'udevadm settle --timeout=5' /rootfs/etc/init.d/tc-config
grep -q 'fstab_pid:-' /rootfs/etc/init.d/tc-config
grep -q 'load_tcz_boot_core' /rootfs/opt/x-chip-boot.sh
grep -q 'load_tcz_onboot_background' /rootfs/opt/x-chip-boot.sh
test -e /rootfs/home/chip/.ssh/authorized_keys || echo "WARN: no authorized_keys file; public image will need manual SSH key setup"
if [ -f /rootfs/etc/wpa_supplicant.conf ]; then
  test -s /rootfs/etc/wpa_supplicant.conf
else
  echo "WARN: no WiFi config; public image will use serial/LCD/USB debug until configured"
fi
test -s /rootfs/usr/share/kmap/pocketchip.kmap
test "$(od -An -tx1 -j264 -N16 /rootfs/usr/share/kmap/pocketchip.kmap | tr -d ' \n')" = "021b0031003200330034003500360037"
test "$(od -An -tx1 -j816 -N10 /rootfs/usr/share/kmap/pocketchip.kmap | tr -d ' \n')" = "0b7b007d005b005d007c"
test -s /rootfs/lib/firmware/rtlwifi/rtl8723bs_nic.bin
find /rootfs/lib/modules -path '*/extra/8812au.ko' -type f | grep -q . || echo "WARN: RTL8812AU module not present"
grep -a -q 'video=Unknown-1:480x272e' /rootfs/boot/boot.scr
grep -a -q 'video=Composite-1:d' /rootfs/boot/boot.scr
grep -a -q 'tce=/tce base' /rootfs/boot/boot.scr
grep -a -q 'DIP: selected' /rootfs/boot/boot.scr
test -f /rootfs/lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo
sync
for _ in $(seq 60); do
  grep -q ' /rootfs ' /proc/mounts || break
  umount /rootfs && break || sleep 1
done
if grep -q ' /rootfs ' /proc/mounts; then
  echo "ERROR: /rootfs still mounted; refusing to detach UBI" >&2
  exit 1
fi
ubidetach -m 4
INNER
    echo ">> flash complete -- remove the FEL jumper and power-cycle into NAND"
}

verify_flashed_rootfs() {
    local key=assets/installer_key
    local ssh="ssh -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.81.1"
    require_file "$key"
    chmod og-rw "$key"

    echo ">> verifying flashed rootfs"
    $ssh 'sh -seu' <<'INNER'
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
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/tmp[[:space:]]+tmpfs[[:space:]]+' /verify-rootfs/etc/fstab
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/run[[:space:]]+tmpfs[[:space:]]+' /verify-rootfs/etc/fstab
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/var/run[[:space:]]+tmpfs[[:space:]]+' /verify-rootfs/etc/fstab
grep -Eq '^[[:space:]]*tmpfs[[:space:]]+/var/lock[[:space:]]+tmpfs[[:space:]]+' /verify-rootfs/etc/fstab
grep -q 'udevadm settle --timeout=5' /verify-rootfs/etc/init.d/tc-config
grep -q 'fstab_pid:-' /verify-rootfs/etc/init.d/tc-config
grep -q 'WAITED' /verify-rootfs/opt/x-chip-tty1-getty.sh
test ! -e /verify-rootfs/opt/x-chip-firstboot.sh
grep -q '192.168.82.1' /verify-rootfs/opt/x-chip-boot.sh
grep -q 'start_usb_debug_gadget' /verify-rootfs/opt/x-chip-boot.sh
grep -q 'load_tcz_boot_core' /verify-rootfs/opt/x-chip-boot.sh
grep -q 'load_tcz_onboot_background' /verify-rootfs/opt/x-chip-boot.sh
grep -q 'start_ssh' /verify-rootfs/opt/x-chip-boot.sh
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

start_installer_usb_ip_watchdog() {
    (
        set +e
        local iface addr
        for _ in $(seq 180); do
            iface=
            for addr in /sys/class/net/*/address; do
                [ "$(cat "$addr" 2>/dev/null)" = "de:ad:be:ef:53:02" ] || continue
                iface=$(basename "$(dirname "$addr")")
                break
            done
            if [ -n "$iface" ]; then
                sudo -n ip addr replace 192.168.81.2/24 dev "$iface" >/dev/null 2>&1 || true
                sudo -n ip link set "$iface" up >/dev/null 2>&1 || true
                if ping -c1 -W1 192.168.81.1 >/dev/null 2>&1; then
                    echo ">> installer USB host IP: $iface 192.168.81.2/24"
                    exit 0
                fi
            fi
            sleep 1
        done
    ) &
    INSTALLER_USB_IP_WATCHDOG=$!
    echo ">> installer USB IP watchdog active"
}

stop_installer_usb_ip_watchdog() {
    [ -n "${INSTALLER_USB_IP_WATCHDOG:-}" ] || return 0
    kill "$INSTALLER_USB_IP_WATCHDOG" >/dev/null 2>&1 || true
    wait "$INSTALLER_USB_IP_WATCHDOG" >/dev/null 2>&1 || true
    unset INSTALLER_USB_IP_WATCHDOG
}

if [ "$DO_FLASH" != 1 ]; then
    echo ">> preflight complete"
    echo ">> connect PocketCHIP in FEL mode, then rerun with --flash"
    exit 0
fi

if [ "$REUSE_INSTALLER" = 1 ]; then
    bind_existing_installer
    install_rootfs_over_existing_installer
    exit 0
fi

echo ">> checking FEL"
sudo -n env PATH="$PATH" sunxi-fel ver

echo ">> flashing TinyCore rootfs"
start_installer_usb_ip_watchdog
flash_status=0
sudo -n env PATH="$PATH" \
    ZIMAGE="$ZIMAGE" \
    DTB="$DTB" \
    UBOOT="$FLASH_TOOLS_DIR/.images/uboot/u-boot-sunxi-with-spl.bin" \
    SPL="$FLASH_TOOLS_DIR/.images/uboot/sunxi-spl.bin" \
    UBOOT_BIN="$FLASH_TOOLS_DIR/.images/uboot/u-boot-dtb.bin" \
    INITRD="$FLASH_TOOLS_DIR/.images/initrd.uimage" \
    "$FLASH_TOOLS_DIR/flash-live.sh" "$FLASH_TOOLS_DIR/$REMOTE_ROOTFS" || flash_status=$?
stop_installer_usb_ip_watchdog
[ "$flash_status" -eq 0 ] || exit "$flash_status"
verify_flashed_rootfs
echo ">> flash complete -- remove the FEL jumper and power-cycle into NAND"
REMOTE
