#!/bin/bash
set -euo pipefail

# Beginner-friendly release flasher.
# Downloads the public rootfs release, verifies it, then delegates the actual
# NAND write to scripts/05-flash-local.sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env

DEFAULT_RELEASE_TAG="${PROJECT_REPO_NAME}-pocketchip-${KERNEL_VERSION}${KERNEL_LOCALVERSION}-2026-07-01"
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
REFRESH_FLASH_SHAS=${REFRESH_FLASH_SHAS:-1}

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
  --no-refresh-flash-shas
                        use pinned flash helper SHA256 values from config.env
  --yes                 skip the final interactive confirmation
  --tag TAG             GitHub release tag to download
  --repo OWNER/REPO     GitHub repository (default: $RELEASE_REPO)
  --download-dir DIR    cache/download directory
  --rootfs FILE         use an existing rootfs tar.gz instead of downloading
  --sha256 FILE         sha256 file for --rootfs
  --base-url URL        release asset base URL
  -h, --help            show this help

Environment overrides use the same names: RELEASE_TAG, RELEASE_REPO,
DOWNLOAD_DIR, RELEASE_ASSET, RELEASE_SHA_ASSET, INSTALL_DEPS,
REFRESH_FLASH_SHAS.
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
        --no-refresh-flash-shas)
            REFRESH_FLASH_SHAS=0
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
  git curl sha256sum sudo tar ssh ping ip dd mkimage sunxi-fel

The NAND SPL image builder may be installed under either name:
  sunxi-nand-image-builder  old linux-sunxi/sunxi-tools misc tool
  sunxi-spl-image-builder   current U-Boot host tool

Ubuntu/Debian sunxi-tools packages often provide sunxi-fel but not the old
sunxi-nand-image-builder misc tool. This script accepts either name. If neither
exists, build one from source and keep it on PATH, or set SNIB=/path/to/tool.
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

select_sunxi_nand_builder() {
    if [ -n "${SNIB:-}" ]; then
        need_cmd "$SNIB" || {
            echo "SNIB is set but not executable or not on PATH: $SNIB" >&2
            exit 1
        }
        export SNIB
        echo ">> using NAND SPL image builder: $SNIB"
        return 0
    fi

    if need_cmd sunxi-nand-image-builder; then
        SNIB=sunxi-nand-image-builder
    elif need_cmd sunxi-spl-image-builder; then
        SNIB=sunxi-spl-image-builder
    else
        cat >&2 <<'EOF'
missing required NAND SPL image builder:
  expected one of:
    sunxi-nand-image-builder
    sunxi-spl-image-builder

Why this happens:
  sunxi-nand-image-builder is the old linux-sunxi/sunxi-tools misc tool used by
  x-chip-tools. Many Ubuntu/Debian sunxi-tools packages install sunxi-fel but do
  not install that misc tool. Newer U-Boot builds provide the same host tool as
  sunxi-spl-image-builder.

Fix:
  install/build either tool and keep it on PATH, or set SNIB=/path/to/tool.
EOF
        exit 1
    fi

    export SNIB
    echo ">> using NAND SPL image builder: $SNIB"
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
    require_commands git curl sha256sum sudo tar ssh ping ip dd mkimage sunxi-fel
    select_sunxi_nand_builder
}

github_release_asset_sha256() {
    local repo=$1 tag=$2 asset=$3
    curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$tag" \
        | tr '\n' ' ' \
        | sed 's/}[[:space:]]*,[[:space:]]*{/\n/g' \
        | awk -v asset="$asset" '
            index($0, "\"name\":\"" asset "\"") || index($0, "\"name\": \"" asset "\"") {
                digest = $0
                sub(/^.*"digest"[[:space:]]*:[[:space:]]*"sha256:/, "", digest)
                if (digest != $0) {
                    sub(/".*$/, "", digest)
                    if (length(digest) == 64) {
                        print tolower(digest)
                        exit
                    }
                }
            }
        '
}

export_flash_sha256() {
    local var=$1 repo=$2 tag=$3 asset=$4 sha
    sha=$(github_release_asset_sha256 "$repo" "$tag" "$asset" 2>/dev/null || true)
    if [ -n "$sha" ]; then
        export "$var=$sha"
        echo ">> $asset sha256: $sha"
    else
        echo ">> could not refresh sha256 for $repo $tag $asset; using config.env fallback" >&2
    fi
}

refresh_flash_sha256s() {
    case "$REFRESH_FLASH_SHAS" in
        0|no|false) return 0 ;;
    esac
    require_commands curl
    echo ">> refreshing flash helper sha256 values from GitHub"
    export_flash_sha256 X_CHIP_INITRD_SHA256 nextthingco/x-chip-tools "${X_CHIP_TOOLS_RELEASE_TAG:-}" initrd.uimage
    export_flash_sha256 X_CHIP_SPL_SHA256 nextthingco/x-chip-uboot "${X_CHIP_UBOOT_RELEASE_TAG:-}" sunxi-spl.bin
    export_flash_sha256 X_CHIP_UBOOT_DTB_SHA256 nextthingco/x-chip-uboot "${X_CHIP_UBOOT_RELEASE_TAG:-}" u-boot-dtb.bin
    export_flash_sha256 X_CHIP_UBOOT_WITH_SPL_SHA256 nextthingco/x-chip-uboot "${X_CHIP_UBOOT_RELEASE_TAG:-}" u-boot-sunxi-with-spl.bin
    export_flash_sha256 X_CHIP_POCKETCHIP_ROOTFS_SHA256 nextthingco/x-chip-os "${X_CHIP_OS_RELEASE_TAG:-}" pocketchip-rootfs.tar.gz
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

refresh_flash_sha256s
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
