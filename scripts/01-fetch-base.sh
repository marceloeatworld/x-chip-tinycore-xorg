#!/bin/bash -e

# Fetch the maintained TinyCore / CorePure armhf base rootfs.
# The upstream release image is RPi-flavored. We keep ONLY the board-agnostic
# CorePure root filesystem (a gzipped newc cpio from the FAT boot partition)
# and discard its RPi kernel/modules/dtb/firmware.

HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
source ./config.env

have_sudo_nopass() { sudo -n true >/dev/null 2>&1; }
need_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif have_sudo_nopass; then
        sudo "$@"
    else
        "$@"
    fi
}

validate_corepure_base() {
    local missing=0 required
    for required in \
        bin/busybox \
        sbin/init \
        init \
        etc/inittab \
        etc/init.d/rcS \
        etc/init.d/tc-config; do
        if [ ! -e "rootfs/$required" ]; then
            echo "ERROR: CorePure extraction missed /$required" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ] || exit 1
}

clean_generated_dir() {
    local path=$1
    [ -e "$path" ] || return 0
    if rm -rf "$path" 2>/dev/null; then
        return 0
    fi
    if command -v podman >/dev/null 2>&1 && podman unshare rm -rf "$PWD/$path" 2>/dev/null; then
        return 0
    fi
    echo "ERROR: could not remove generated build/$path" >&2
    echo "Try: podman unshare rm -rf '$PWD/$path'" >&2
    exit 1
}

extract_corepure_rootfs() {
    local rootfs_gz=$1 cpio_log bad_log cpio_status

    (
        cd rootfs
        cpio_log=../cpio-extract.log
        bad_log=../cpio-extract.bad.log
        rm -f "$cpio_log" "$bad_log"

        set +e
        if [ "$(id -u)" = 0 ]; then
            zcat "../$rootfs_gz" | cpio -idm 2>"$cpio_log"
        elif have_sudo_nopass; then
            zcat "../$rootfs_gz" | sudo cpio -idm 2>"$cpio_log"
        else
            zcat "../$rootfs_gz" | cpio -idm 2>"$cpio_log"
        fi
        cpio_status=${PIPESTATUS[1]}
        set -e

        if [ "$cpio_status" -ne 0 ]; then
            grep -vE '^cpio: dev/.+: Cannot mknod: Operation not permitted$|^[0-9]+ blocks$' \
                "$cpio_log" >"$bad_log" || true
            if [ -s "$bad_log" ]; then
                cat "$bad_log" >&2
                exit "$cpio_status"
            fi
            echo ">> static /dev nodes skipped; devtmpfs and assembly will populate /dev at boot"
        fi
        rm -f "$cpio_log" "$bad_log"
        mkdir -p dev proc sys run tmp
        chmod 1777 tmp
    )

    validate_corepure_base
}

mkdir -p build && cd build

BASE_FILE=${TINYCORE_BASE_FILE:-$(basename "$TINYCORE_BASE_URL")}
[ -f "$BASE_FILE" ] || curl -fSL -o "$BASE_FILE" "$TINYCORE_BASE_URL"

clean_generated_dir base
clean_generated_dir extracted
clean_generated_dir zip
clean_generated_dir rootfs
mkdir -p base rootfs

case "$BASE_FILE" in
    *.zip)
        ( cd base && unzip -o "../$BASE_FILE" )
        ;;
    *.img.gz)
        gzip -dc "$BASE_FILE" >"base/${BASE_FILE%.gz}"
        ;;
    *.img)
        cp "$BASE_FILE" base/
        ;;
    *)
        echo "ERROR: unsupported TinyCore base format: $BASE_FILE" >&2
        exit 1
        ;;
esac

ROOTFS_GZ=$(find base -name 'rootfs-piCore*.gz' | sort | head -1)
if [ -z "$ROOTFS_GZ" ]; then
    IMG=$(find base -name 'piCore-*.img' | sort | head -1)
    [ -n "$IMG" ] || { echo "ERROR: upstream TinyCore image not found in $BASE_FILE" >&2; exit 1; }
    command -v fdisk >/dev/null || { echo "need fdisk to locate the TinyCore FAT partition" >&2; exit 1; }
    command -v mcopy >/dev/null || { echo "need mtools (mcopy) to extract rootfs from the TinyCore image" >&2; exit 1; }

    START_SECTOR=$(fdisk -l "$IMG" | awk -v part="${IMG}1" '$1 == part {print $2; exit}')
    [ -n "$START_SECTOR" ] || { echo "ERROR: could not locate FAT partition in $IMG" >&2; exit 1; }
    FAT_OFFSET=$(( START_SECTOR * 512 ))
    mkdir -p base/extracted
    mcopy -i "$IMG@@$FAT_OFFSET" "::/rootfs-piCore*.gz" base/extracted/
    ROOTFS_GZ=$(find base/extracted -name 'rootfs-piCore*.gz' | sort | head -1)
fi
[ -n "$ROOTFS_GZ" ] || { echo "ERROR: CorePure rootfs not found in $BASE_FILE" >&2; exit 1; }
echo ">> CorePure base: $ROOTFS_GZ"

extract_corepure_rootfs "$ROOTFS_GZ"

echo ">> CorePure base unpacked to build/rootfs"
