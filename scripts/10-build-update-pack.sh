#!/bin/bash
set -euo pipefail

# Builds the "update pack" applied on-device by x-chip-update: the system-owned
# subset of the verified release rootfs. /home, /etc, and SSH host keys stay
# out so an in-place update never clobbers user state.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

ROOTFS=${1:-${ROOTFS:-$OUT}}
RELEASE_NAME=${RELEASE_NAME:-${PROJECT_REPO_NAME}-pocketchip-${KERNEL_VERSION}${KERNEL_LOCALVERSION}}
DIST_DIR=${DIST_DIR:-dist}
OUT_DIR=${OUT_DIR:-$DIST_DIR/$RELEASE_NAME}

# Project-built .tcz apps shipped in /tce/optional. TinyCore upstream
# extensions are excluded: those update on-device with tce-update.
COMMUNITY_APPS=(goattracker sunvox virtual-ans pixitracker pixitracker-1bit pixilang tic80 mgba doom)

[ -f "$ROOTFS" ] || {
    echo "missing rootfs: $ROOTFS" >&2
    exit 1
}

STAGE=$(mktemp -d)
LIST=$(mktemp)
PACK_LIST=$(mktemp)
trap 'rm -rf "$STAGE"; rm -f "$LIST" "$PACK_LIST"' EXIT

tar -tzf "$ROOTFS" >"$LIST"

# Member names must not overlap: tar extracts a directory name recursively and
# then reports the (already extracted) children given alongside it as "Not
# found in archive". Pass whole directories plus non-overlapping file matches.
collect_members() {
    local prefix app
    for prefix in ./boot/ ./lib/modules/ ./lib/firmware/nextthingco/ ./opt/ ./usr/local/share/x-chip/; do
        if grep -Fxq "$prefix" "$LIST"; then
            printf '%s\n' "$prefix"
        else
            echo "WARN: $prefix missing from $ROOTFS; skipping" >&2
        fi
    done
    grep -E '^\./usr/local/(bin|sbin)/x-chip' "$LIST" || true
    grep -E '^\./tce/[^/]+\.lst$' "$LIST" || true
    for app in "${COMMUNITY_APPS[@]}"; do
        grep -E "^\./tce/optional/$app\.tcz" "$LIST" || true
    done
}
collect_members | sort -u >"$PACK_LIST"

[ -s "$PACK_LIST" ] || {
    echo "ERROR: no update pack members matched in $ROOTFS" >&2
    exit 1
}

tar -xzf "$ROOTFS" -C "$STAGE" -p -T "$PACK_LIST"
# applied-release is device state written by x-chip-update, never shipped.
rm -f "$STAGE/usr/local/share/x-chip/applied-release"

mkdir -p "$OUT_DIR"
pack_out="$OUT_DIR/$RELEASE_NAME.update.tar.gz"
case "$pack_out" in
    /*) pack_abs=$pack_out ;;
    *)  pack_abs=$HERE/$pack_out ;;
esac
# Everything in the pack is system-owned root:root in the image; force that
# here because the staging extract ran unprivileged.
(cd "$STAGE" && tar --numeric-owner --owner=0 --group=0 -czf "$pack_abs" .)
(cd "$OUT_DIR" && sha256sum "$(basename "$pack_out")" >"$(basename "$pack_out").sha256")

echo ">> update pack: $pack_out ($(wc -l <"$PACK_LIST") members)"
sha256sum "$pack_out"
