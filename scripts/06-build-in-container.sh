#!/bin/bash
set -euo pipefail

# Reproducible container build wrapper.
# It mounts the sibling board-data repos and host-only inputs explicitly so the
# produced rootfs does not silently miss SSH keys, firmware, or the keymap.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    REQUIRE_WIFI_CONFIG=0
    REQUIRE_AUTHORIZED_KEYS=0
    SECRETS_ENV=/dev/null
fi

DOCKER=${DOCKER:-docker}
IMAGE=${IMAGE:-x-chip-tc}
EMPTY_KEYS=
cleanup() {
    if [ -n "$EMPTY_KEYS" ]; then
        rm -f "$EMPTY_KEYS"
    fi
    return 0
}
trap cleanup EXIT

resolve_existing() {
    local value=$1
    case "$value" in
        "") return 1 ;;
        /*) [ -e "$value" ] && printf '%s\n' "$value" ;;
        *)  [ -e "$HERE/$value" ] && printf '%s\n' "$HERE/$value" ;;
    esac
}

pick_authorized_keys() {
    local candidate
    for candidate in \
        "${AUTHORIZED_KEYS_SOURCE:-}" \
        "$HERE/../flash/rootfs_trixie/home/chip/.ssh/authorized_keys" \
        "$HOME/.ssh/pocket.pub" \
        "$HOME/.ssh/id_ed25519.pub"; do
        [ -n "$candidate" ] || continue
        [ -s "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

KEYMAP_HOST=
for candidate in \
    "${KEYMAP_SOURCE:-}" \
    "../chip-debroot/deb_files/usr/local/share/keymaps/pocketchip.kmap" \
    "../pocketchip.kmap"; do
    [ -n "$candidate" ] || continue
    KEYMAP_HOST=$(resolve_existing "$candidate" || true)
    [ -n "$KEYMAP_HOST" ] && break
done
if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 0 ]; then
    EMPTY_KEYS=$(mktemp)
    AUTHORIZED_KEYS_HOST=$EMPTY_KEYS
else
    AUTHORIZED_KEYS_HOST=$(pick_authorized_keys || true)
fi
FLASH_HOST=$(resolve_existing "${FLASH_SOURCE:-../flash}" || true)
CHIP_DEBROOT_HOST=$(resolve_existing "${CHIP_DEBROOT_SOURCE:-../chip-debroot}" || true)

[ -n "$KEYMAP_HOST" ] || { echo "missing keymap: run make deps or set KEYMAP_SOURCE" >&2; exit 1; }
[ -n "$AUTHORIZED_KEYS_HOST" ] || { echo "missing authorized_keys: set AUTHORIZED_KEYS_SOURCE or create ~/.ssh/pocket.pub" >&2; exit 1; }
[ -n "$CHIP_DEBROOT_HOST" ] || { echo "missing chip-debroot: set CHIP_DEBROOT_SOURCE or place ../chip-debroot" >&2; exit 1; }

echo ">> building container image: $IMAGE"
"$DOCKER" build -t "$IMAGE" .

echo ">> using authorized keys: $AUTHORIZED_KEYS_HOST"
echo ">> using keymap: $KEYMAP_HOST"
echo ">> using chip-debroot: $CHIP_DEBROOT_HOST"

DOCKER_ARGS=(
    --rm
    -v "$HERE:/work" \
    -v "$CHIP_DEBROOT_HOST:/chip-debroot:ro" \
    -v "$AUTHORIZED_KEYS_HOST:/inputs/authorized_keys:ro" \
    -v "$KEYMAP_HOST:/inputs/pocketchip.kmap:ro" \
    -e CHIP_KERNEL_PATCHES=/chip-debroot/kernel_files \
    -e CHIP_DTS_DIR=/chip-debroot/devicetree \
    -e AUTHORIZED_KEYS_SOURCE=/inputs/authorized_keys \
    -e KEYMAP_SOURCE=/inputs/pocketchip.kmap \
    -e SECRETS_ENV="${SECRETS_ENV:-./secrets.env}" \
    -e REQUIRE_WIFI_CONFIG="${REQUIRE_WIFI_CONFIG:-1}" \
    -e REQUIRE_AUTHORIZED_KEYS="${REQUIRE_AUTHORIZED_KEYS:-1}" \
    -e PUBLIC_IMAGE="${PUBLIC_IMAGE:-0}" \
    -e SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-}" \
    -e SSH_PASSWORD="${SSH_PASSWORD:-chip}" \
    -e SSH_PASSWORD_HASH="${SSH_PASSWORD_HASH:-}" \
    -e SSH_PASSWORD_SALT="${SSH_PASSWORD_SALT:-}" \
    -e PRESEED_TCZ="${PRESEED_TCZ:-1}" \
    -e INCLUDE_PRIVATE_ROMS="${INCLUDE_PRIVATE_ROMS:-0}" \
    -e PRIVATE_ROMS_DIR="${PRIVATE_ROMS_DIR:-dist/private-roms/GameBoy}" \
    -e COMMUNITY_TCZ_DIR="${COMMUNITY_TCZ_DIR:-dist/community-tcz}" \
    -e OUT="$OUT" \
    -e ROOTFS_FORCE_FAKEROOT=1 \
)

if [ -n "$FLASH_HOST" ]; then
    echo ">> using flash data: $FLASH_HOST"
    DOCKER_ARGS+=(
        -v "$FLASH_HOST:/flash:ro"
        -e EXTRA_FIRMWARE_SOURCE=/flash/rootfs_trixie/usr/lib/firmware
    )
else
    echo ">> flash data not found; using firmware-rtlwifi.tcz fallback"
    DOCKER_ARGS+=(-e EXTRA_FIRMWARE_SOURCE=/missing-firmware)
fi

"$DOCKER" run "${DOCKER_ARGS[@]}" "$IMAGE" make

sha256sum "$OUT"
