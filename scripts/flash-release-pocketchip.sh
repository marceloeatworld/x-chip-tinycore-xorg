#!/bin/bash
set -euo pipefail

# Beginner-friendly release flasher.
# Downloads the public rootfs release, verifies it, then delegates the actual
# NAND write to scripts/05-flash-local.sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

DEFAULT_RELEASE_TAG="${PROJECT_REPO_NAME}-pocketchip-${KERNEL_VERSION}${KERNEL_LOCALVERSION}-2026-06-29"
RELEASE_TAG=${RELEASE_TAG:-$DEFAULT_RELEASE_TAG}
RELEASE_REPO=${RELEASE_REPO:-${PROJECT_GITHUB_OWNER}/${PROJECT_REPO_NAME}}
RELEASE_NAME=${RELEASE_NAME:-${PROJECT_REPO_NAME}-pocketchip-${KERNEL_VERSION}${KERNEL_LOCALVERSION}}
RELEASE_ASSET=${RELEASE_ASSET:-${RELEASE_NAME}.rootfs.tar.gz}
RELEASE_SHA_ASSET=${RELEASE_SHA_ASSET:-${RELEASE_ASSET}.sha256}
CACHE_ROOT=${XDG_CACHE_HOME:-$HOME/.cache}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-}

ROOTFS_OVERRIDE=
SHA256_OVERRIDE=
BASE_URL_OVERRIDE=
DRY_RUN=0
DOWNLOAD_ONLY=0
ASSUME_YES=0
PREFLIGHT=0
INSTALL_DEPS=${INSTALL_DEPS:-ask}

usage() {
    cat <<EOF
usage: $0 [options]

Downloads and flashes the current public PocketCHIP TinyCore Xorg release.
By default this will erase and rewrite the PocketCHIP NAND after confirmation.

Options:
  --dry-run             download, verify, and check commands only
  --preflight           also run the low-level flasher preflight; needs sudo
  --download-only       download and verify the release only
  --install-deps        install missing Debian/Ubuntu host packages with apt
  --no-install-deps     only report missing host commands
  --yes                 skip the final interactive confirmation
  --tag TAG             GitHub release tag to download
  --repo OWNER/REPO     GitHub repository (default: $RELEASE_REPO)
  --download-dir DIR    cache/download directory
  --rootfs FILE         use an existing rootfs tar.gz instead of downloading
  --sha256 FILE         sha256 file for --rootfs
  --base-url URL        release asset base URL
  -h, --help            show this help

Environment overrides use the same names: RELEASE_TAG, RELEASE_REPO,
DOWNLOAD_DIR, RELEASE_ASSET, RELEASE_SHA_ASSET, INSTALL_DEPS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --preflight)
            DRY_RUN=1
            PREFLIGHT=1
            ;;
        --download-only)
            DOWNLOAD_ONLY=1
            ;;
        --install-deps)
            INSTALL_DEPS=yes
            ;;
        --no-install-deps)
            INSTALL_DEPS=no
            ;;
        --yes)
            ASSUME_YES=1
            ;;
        --tag)
            RELEASE_TAG=${2:?missing value for --tag}
            shift
            ;;
        --repo)
            RELEASE_REPO=${2:?missing value for --repo}
            shift
            ;;
        --download-dir)
            DOWNLOAD_DIR=${2:?missing value for --download-dir}
            shift
            ;;
        --rootfs)
            ROOTFS_OVERRIDE=${2:?missing value for --rootfs}
            shift
            ;;
        --sha256)
            SHA256_OVERRIDE=${2:?missing value for --sha256}
            shift
            ;;
        --base-url)
            BASE_URL_OVERRIDE=${2:?missing value for --base-url}
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

DOWNLOAD_DIR=${DOWNLOAD_DIR:-$CACHE_ROOT/x-chip-tinycore-xorg/releases/$RELEASE_TAG}
RELEASE_BASE_URL=${BASE_URL_OVERRIDE:-https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG}

if [ -n "$ROOTFS_OVERRIDE" ]; then
    ROOTFS=$ROOTFS_OVERRIDE
    SHA256_FILE=${SHA256_OVERRIDE:-${ROOTFS}.sha256}
else
    ROOTFS=$DOWNLOAD_DIR/$RELEASE_ASSET
    SHA256_FILE=$DOWNLOAD_DIR/$RELEASE_SHA_ASSET
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || return 1
}

missing_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        need_cmd "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s\n' "${missing[@]}"
        return 1
    fi
}

print_install_hint() {
    cat >&2 <<'EOF'

Install the missing commands, then run this script again.

On Debian/Ubuntu this is usually close to:
  sudo apt-get update
  sudo apt-get install git curl ca-certificates openssh-client iproute2 iputils-ping u-boot-tools sunxi-tools

The required command names are:
  git curl sha256sum sudo tar ssh ping ip dd mkimage sunxi-fel sunxi-nand-image-builder

If your distro's sunxi-tools package does not include
sunxi-nand-image-builder, install a sunxi-tools build that provides it and keep
it on PATH.
EOF
}

install_deps_with_apt() {
    local answer packages
    if ! need_cmd apt-get; then
        echo ">> automatic package install unavailable: apt-get not found" >&2
        return 1
    fi

    case "$INSTALL_DEPS" in
        yes|true|1)
            ;;
        no|false|0)
            echo ">> automatic package install disabled by --no-install-deps" >&2
            return 1
            ;;
        *)
            if [ ! -t 0 ]; then
                echo ">> automatic package install skipped: non-interactive shell" >&2
                echo ">> rerun with --install-deps to allow apt-get package install" >&2
                return 1
            fi
            printf 'Install common Debian/Ubuntu flashing packages now? [y/N] '
            read -r answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *)
                    echo ">> package install skipped by user" >&2
                    return 1
                    ;;
            esac
            ;;
    esac

    packages="git curl ca-certificates openssh-client iproute2 iputils-ping u-boot-tools sunxi-tools"
    echo ">> installing host packages with apt-get"
    if [ "$EUID" -eq 0 ]; then
        apt-get update
        apt-get install -y $packages
    else
        need_cmd sudo || {
            echo ">> automatic package install unavailable: sudo not found" >&2
            return 1
        }
        sudo -v
        sudo apt-get update
        sudo apt-get install -y $packages
    fi
}

require_commands() {
    local missing
    if ! missing=$(missing_commands "$@"); then
        if install_deps_with_apt; then
            missing=$(missing_commands "$@") || true
            [ -z "$missing" ] && return 0
        fi
        echo "missing required command(s):" >&2
        while IFS= read -r cmd; do
            [ -n "$cmd" ] && printf '  %s\n' "$cmd" >&2
        done <<EOF
$missing
EOF
        print_install_hint
        exit 1
    fi
}

download_asset() {
    local name=$1 dest=$2 url tmp
    if [ -f "$dest" ]; then
        echo ">> using cached $(basename "$dest")"
        return 0
    fi

    require_commands curl
    mkdir -p "$(dirname "$dest")"
    url=$RELEASE_BASE_URL/$name
    tmp=$dest.part.$$
    rm -f "$tmp"
    echo ">> downloading $name"
    if curl -fL --retry 3 --connect-timeout 20 --remove-on-error -o "$tmp" "$url"; then
        [ -s "$tmp" ] || { echo "empty download: $url" >&2; rm -f "$tmp"; exit 1; }
        mv -f "$tmp" "$dest"
    else
        rm -f "$tmp"
        exit 1
    fi
}

verify_rootfs() {
    local expected actual
    [ -f "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS" >&2; exit 1; }
    [ -f "$SHA256_FILE" ] || { echo "missing sha256 file: $SHA256_FILE" >&2; exit 1; }
    require_commands sha256sum

    expected=$(awk 'NF { print $1; exit }' "$SHA256_FILE")
    [ -n "$expected" ] || { echo "sha256 file is empty: $SHA256_FILE" >&2; exit 1; }
    actual=$(sha256sum "$ROOTFS" | awk '{ print $1 }')
    if [ "$actual" != "$expected" ]; then
        echo "sha256 mismatch:" >&2
        echo "  file:     $ROOTFS" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
    echo ">> verified rootfs sha256: $actual"
}

download_release() {
    if [ -n "$ROOTFS_OVERRIDE" ]; then
        echo ">> using local rootfs: $ROOTFS"
        return 0
    fi
    echo ">> release: $RELEASE_REPO $RELEASE_TAG"
    download_asset "$RELEASE_ASSET" "$ROOTFS"
    download_asset "$RELEASE_SHA_ASSET" "$SHA256_FILE"
}

check_flash_commands() {
    require_commands git curl sha256sum sudo tar ssh ping ip dd mkimage sunxi-fel sunxi-nand-image-builder
}

check_sudo() {
    echo ">> sudo check"
    sudo -v
}

print_fel_steps() {
    cat <<EOF

FEL/GND setup:
  1. Power the PocketCHIP off.
  2. Connect FEL to GND with one jumper wire.
  3. Keep FEL connected to GND.
  4. Plug the PocketCHIP micro-USB cable into this Linux PC.

Do not connect FEL to 5V, VBAT, or 3V3.
This flash will erase the PocketCHIP NAND.
EOF
}

download_release
verify_rootfs

if [ "$DOWNLOAD_ONLY" = 1 ]; then
    echo ">> download-only complete"
    exit 0
fi

check_flash_commands

if [ "$DRY_RUN" = 1 ]; then
    if [ "$PREFLIGHT" = 1 ]; then
        check_sudo
        echo ">> running local flasher preflight only"
        ./scripts/05-flash-local.sh --rootfs "$ROOTFS"
    fi
    echo ">> dry-run complete; no NAND write was attempted"
    exit 0
fi

check_sudo
print_fel_steps
if [ "$ASSUME_YES" != 1 ]; then
    if [ ! -t 0 ]; then
        echo "non-interactive shell; rerun with --yes only when FEL is connected" >&2
        exit 1
    fi
    printf '\nType FLASH when the PocketCHIP is connected in FEL mode: '
    read -r answer
    [ "$answer" = "FLASH" ] || {
        echo "aborted; nothing was flashed"
        exit 0
    }
fi

./scripts/05-flash-local.sh --rootfs "$ROOTFS" --flash
