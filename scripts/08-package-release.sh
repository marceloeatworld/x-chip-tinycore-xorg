#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    REQUIRE_WIFI_CONFIG=0
    REQUIRE_AUTHORIZED_KEYS=0
fi

ROOTFS=${1:-${ROOTFS:-$OUT}}
RELEASE_NAME=${RELEASE_NAME:-${PROJECT_REPO_NAME}-pocketchip-${KERNEL_VERSION}${KERNEL_LOCALVERSION}}
DIST_DIR=${DIST_DIR:-dist}

[ -f "$ROOTFS" ] || {
    echo "missing rootfs: $ROOTFS" >&2
    exit 1
}

extract_entry() {
    local path=${1#/}
    tar -xOzf "$ROOTFS" "./$path" 2>/dev/null || tar -xOzf "$ROOTFS" "$path" 2>/dev/null || true
}

entry_exists() {
    local path=${1#/}
    tar -tzf "$ROOTFS" "./$path" >/dev/null 2>&1 || tar -tzf "$ROOTFS" "$path" >/dev/null 2>&1
}

auth_bytes=0
if entry_exists "home/$SSH_USER/.ssh/authorized_keys"; then
    auth_bytes=$(extract_entry "home/$SSH_USER/.ssh/authorized_keys" | wc -c)
fi

has_wifi=0
if entry_exists etc/wpa_supplicant.conf; then
    has_wifi=1
fi
ssh_password_auth=$(extract_entry usr/local/etc/ssh/sshd_config | awk 'tolower($1) == "passwordauthentication" { print tolower($2) }' | tail -n 1)
[ -n "$ssh_password_auth" ] || ssh_password_auth=unknown

if { [ "$auth_bytes" -gt 0 ] || [ "$has_wifi" = 1 ]; } && [ "${ALLOW_PERSONAL_RELEASE:-0}" != 1 ]; then
    cat >&2 <<EOF
ERROR: refusing to package a personal image for public release.

This rootfs contains:
  authorized_keys bytes: $auth_bytes
  WiFi config present:  $has_wifi

For a public no-secret binary release, build:
  make public-rootfs
  make public-release

For a private/internal backup package only:
  ALLOW_PERSONAL_RELEASE=1 ./scripts/08-package-release.sh
EOF
    exit 1
fi

if [ "${ALLOW_PERSONAL_RELEASE:-0}" = 1 ]; then
    ./scripts/07-verify-rootfs.sh "$ROOTFS"
else
    PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 ./scripts/07-verify-rootfs.sh "$ROOTFS"
fi

release_dir="$DIST_DIR/$RELEASE_NAME"
mkdir -p "$release_dir"

rootfs_out="$release_dir/$RELEASE_NAME.rootfs.tar.gz"
cp "$ROOTFS" "$rootfs_out"
(cd "$release_dir" && sha256sum "$(basename "$rootfs_out")" >"$(basename "$rootfs_out").sha256")

RELEASE_NAME="$RELEASE_NAME" DIST_DIR="$DIST_DIR" ./scripts/10-build-update-pack.sh "$rootfs_out"
pack_out="$release_dir/$RELEASE_NAME.update.tar.gz"
pack_sha=$(sha256sum "$pack_out" | awk '{print $1}')

git_rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
rootfs_sha=$(sha256sum "$rootfs_out" | awk '{print $1}')

cat >"$release_dir/MANIFEST.txt" <<EOF
name=$RELEASE_NAME
generated_at_utc=$generated_at
source_git_rev=$git_rev
source_repo=$PROJECT_REPO_URL
kernel_version=$KERNEL_VERSION
kernel_localversion=$KERNEL_LOCALVERSION
kernel_release=${KERNEL_VERSION}${KERNEL_LOCALVERSION}
tinycore_version=$TINYCORE_VERSION
tcz_repo=$TCZ_REPO
rootfs_file=$(basename "$rootfs_out")
rootfs_sha256=$rootfs_sha
update_pack_file=$(basename "$pack_out")
update_pack_sha256=$pack_sha
contains_wifi_config=$has_wifi
authorized_keys_bytes=$auth_bytes
public_image=$([ "${ALLOW_PERSONAL_RELEASE:-0}" = 1 ] && echo 0 || echo 1)
ssh_user=$SSH_USER
ssh_password_auth=$ssh_password_auth
EOF

if [ "${ALLOW_PERSONAL_RELEASE:-0}" = 1 ]; then
    access_notes="Personal image metadata:
WiFi config included: $has_wifi
SSH authorized_keys bytes: $auth_bytes
SSH password login enabled: $ssh_password_auth

Do not publish this image unless you intentionally want to distribute those credentials."
else
    access_notes="Public images contain no WiFi PSK and no SSH authorized key.
SSH password login is enabled for user \"$SSH_USER\".
Default public password: chip
Change it after first login with: passwd

For automatic WiFi or key-only SSH, build a personal image from source with secrets.env."
fi

cat >"$release_dir/README-release.txt" <<EOF
x-chip-tinycore-xorg PocketCHIP rootfs image

Source: $PROJECT_REPO_URL

File: $(basename "$rootfs_out")

Verify:
  sha256sum -c $(basename "$rootfs_out").sha256

Flash locally:
  1. Connect FEL to GND.
  2. Plug CHIP/PocketCHIP USB into the Linux flashing machine.
  3. Run:
     ./scripts/05-flash-local.sh --rootfs $(basename "$rootfs_out") --flash

Flash through another Linux host:
  ./scripts/05-flash-via-host.sh --host <host> --rootfs $(basename "$rootfs_out") --flash

After flashing, remove the FEL jumper and reboot.

Update an already-flashed device without reflashing (keeps /home and WiFi):
  On the PocketCHIP, run: sudo x-chip-update

$access_notes
EOF

echo ">> release package: $release_dir"
echo ">> sha256: $rootfs_sha"
