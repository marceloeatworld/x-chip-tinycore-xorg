#!/bin/bash
set -euo pipefail

# Build optional community .tcz extensions for apps that are useful on the
# PocketCHIP but intentionally not part of the base image. The host side only
# starts a Debian container; all build products stay under build/ and dist/.

HERE=$(cd "$(dirname "$0")/.." && pwd)

if [ "${X_CHIP_COMMUNITY_TCZ_IN_CONTAINER:-0}" != 1 ]; then
    command -v docker >/dev/null || {
        echo "ERROR: docker is required for the community .tcz build" >&2
        exit 1
    }
    image=${COMMUNITY_TCZ_IMAGE:-debian:trixie}
    exec docker run --rm \
        -e X_CHIP_COMMUNITY_TCZ_IN_CONTAINER=1 \
        -e COMMUNITY_APT_UPDATED=0 \
        -v "$HERE:/work" \
        -w /work \
        "$image" \
        /work/scripts/09-build-community-tcz.sh "$@"
fi

cd /work

OUT_DIR=${OUT_DIR:-/work/dist/community-tcz}
WORK_DIR=${WORK_DIR:-/work/build/community-tcz}
GOATTRACKER_VERSION=${GOATTRACKER_VERSION:-2.77+ds-1}
SUNVOX_VERSION=${SUNVOX_VERSION:-2.1.4d}
SUNVOX_URL=${SUNVOX_URL:-https://warmplace.ru/soft/sunvox/sunvox-${SUNVOX_VERSION}.zip}
VIRTUAL_ANS_VERSION=${VIRTUAL_ANS_VERSION:-3.0.4}
VIRTUAL_ANS_URL=${VIRTUAL_ANS_URL:-https://warmplace.ru/soft/ans/virtual_ans-${VIRTUAL_ANS_VERSION}.zip}
PIXITRACKER_VERSION=${PIXITRACKER_VERSION:-1.6.8}
PIXITRACKER_URL=${PIXITRACKER_URL:-https://warmplace.ru/soft/pixitracker/pixitracker-${PIXITRACKER_VERSION}.zip}
PIXITRACKER_1BIT_URL=${PIXITRACKER_1BIT_URL:-https://warmplace.ru/soft/pixitracker/pixitracker_1bit-${PIXITRACKER_VERSION}.zip}
PIXILANG_VERSION=${PIXILANG_VERSION:-3.8.6f}
PIXILANG_URL=${PIXILANG_URL:-https://warmplace.ru/soft/pixilang/pixilang-${PIXILANG_VERSION}.zip}
TIC80_TAG=${TIC80_TAG:-v1.1.2837}
MGBA_TAG=${MGBA_TAG:-0.10.5}
CHOCOLATE_DOOM_TAG=${CHOCOLATE_DOOM_TAG:-chocolate-doom-3.1.1}
FREEDOOM_VERSION=${FREEDOOM_VERSION:-0.13.0}

# Upstream archives and tags are mutable; pin what actually ships. Update the
# pin together with the version when bumping.
SUNVOX_SHA256=${SUNVOX_SHA256:-acd94ae4acd6ab60bee1f5ba117082cd2ea51f7e87871f1776d11cfd24a59880}
VIRTUAL_ANS_SHA256=${VIRTUAL_ANS_SHA256:-e263aaba6d316723d9a6627423389f725b6305cb2c6272ac79cfb4e0a32e3eb3}
PIXITRACKER_SHA256=${PIXITRACKER_SHA256:-1ef52342cf4572352c0becf2a493ba909ba140fe2b06bfa4b5f350247b8ddf91}
PIXITRACKER_1BIT_SHA256=${PIXITRACKER_1BIT_SHA256:-5810cdbfa36d67f6c82249eed0fc2b834e747edd06f4bea901391ca747df2e69}
PIXILANG_SHA256=${PIXILANG_SHA256:-9ae85db1226396a46ae5110ef360db7873c3054a29e70002d6272dea84c3a64d}
FREEDOOM_SHA256=${FREEDOOM_SHA256:-3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59}
TIC80_COMMIT=${TIC80_COMMIT:-be42d6f146cfa520b9b1050feba10cc8c14fb3bd}
MGBA_COMMIT=${MGBA_COMMIT:-26b7884bc25a5933960f3cdcd98bac1ae14d42e2}
CHOCOLATE_DOOM_COMMIT=${CHOCOLATE_DOOM_COMMIT:-410d96855b5df5410ff591a90efeafa889119224}
JOBS=${JOBS:-$(nproc)}

apps=("$@")
if [ "${#apps[@]}" = 0 ]; then
    apps=(goattracker sunvox pixitracker pixitracker-1bit pixilang tic80 mgba doom)
fi

apt_updated=0
apt_update_once() {
    if [ "$apt_updated" = 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        dpkg --add-architecture armhf
        if ! grep -Rqs '^deb-src .*debian.* trixie ' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
            echo 'deb-src http://deb.debian.org/debian trixie main' >/etc/apt/sources.list.d/debian-src.list
        fi
        apt-get update
        apt_updated=1
    fi
}

apt_install() {
    apt_update_once
    apt-get install -y --no-install-recommends "$@"
}

verify_sha256() {
    local file=$1 expected=$2 actual
    [ -n "$expected" ] || return 0
    actual=$(sha256sum "$file" | awk '{ print $1 }')
    [ "$actual" = "$expected" ] || {
        echo "ERROR: sha256 mismatch for $file" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

download_file() {
    local url=$1 dest=$2 expected_sha=${3:-} tmp
    tmp="$dest.part.$$"
    rm -f "$tmp"
    if wget -q -O "$tmp" "$url"; then
        [ -s "$tmp" ] || { echo "ERROR: empty download: $url" >&2; rm -f "$tmp"; exit 1; }
        verify_sha256 "$tmp" "$expected_sha"
        mv -f "$tmp" "$dest"
    else
        rm -f "$tmp"
        exit 1
    fi
}

require_pinned_commit() {
    local repo_dir=$1 expected=$2 label=$3 actual
    actual=$(git -C "$repo_dir" rev-parse HEAD)
    [ "$actual" = "$expected" ] || {
        echo "ERROR: $label tag no longer points at the pinned commit" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

install_common_tools() {
    apt_install ca-certificates build-essential crossbuild-essential-armhf \
        file squashfs-tools xz-utils
}

stage_info() {
    local name=$1 version=$2 license=$3 site=$4 description=$5 deps=$6 info=$7
    local size
    size=$(du -h "$OUT_DIR/$name.tcz" | awk '{print $1}')
    cat >"$OUT_DIR/$name.tcz.info" <<EOF
Title:          $name.tcz
Description:    $description
Version:        $version
Author:         upstream project contributors
Original-site:  $site
Copying-policy: $license
Size:           $size
Extension_by:   x-chip-tinycore-xorg
Tags:           pocketchip tinycore xorg optional
Comments:       Optional PocketCHIP community extension.
                Not loaded by the base image. Install explicitly with:
                tce-load -il $name.tcz
                Runtime deps:
$deps
                Build notes:
$info
Change-log:     2026/06/27 first x-chip-tinycore-xorg recipe
Current:        2026/06/27 first x-chip-tinycore-xorg recipe
EOF
}

make_tcz() {
    local name=$1 root=$2
    mkdir -p "$OUT_DIR"
    rm -f "$OUT_DIR/$name.tcz" "$OUT_DIR/$name.tcz.md5.txt" "$OUT_DIR/$name.tcz.list"
    mksquashfs "$root" "$OUT_DIR/$name.tcz" -noappend -all-root >/dev/null
    ( cd "$OUT_DIR" && md5sum "$name.tcz" >"$name.tcz.md5.txt" )
    ( cd "$root" && find . -type f -o -type l ) | sed 's|^\./|/|' | sort >"$OUT_DIR/$name.tcz.list"
}

build_goattracker() {
    echo ">> building goattracker.tcz from Debian source $GOATTRACKER_VERSION"
    install_common_tools
    apt_install dpkg-dev libsdl1.2-dev libsdl1.2-dev:armhf libxext-dev:armhf

    local work="$WORK_DIR/goattracker"
    rm -rf "$work"
    mkdir -p "$work"
    ( cd "$work" && apt-get source "goattracker=$GOATTRACKER_VERSION" )

    local src
    src=$(find "$work" -maxdepth 1 -type d -name 'goattracker-*' | sort | head -1)
    [ -n "$src" ] || { echo "ERROR: goattracker source extraction failed" >&2; exit 1; }

    # Cross-build fix: bme/datafile and bme/dat2inc are native generator tools,
    # while the final app is armhf. Upstream makefiles also hard-code strip/gcc.
    perl -0pi -e 's/\x60sdl-config --cflags\x60/\x60\$(SDL_CONFIG) --cflags\x60/g;
                  s/\x60sdl-config --libs\x60/\x60\$(SDL_CONFIG) --libs\x60/g;
                  s/\n\tstrip /\n\t\$(STRIP) /g;
                  s/\n\tgcc -o/\n\t\$(CC) -o/g' \
        "$src/src/makefile" "$src/src/makefile.common" "$src/src/bme/makefile"

    make -C "$src/src/bme" -j"$JOBS" CC=gcc STRIP=true SDL_CONFIG=sdl-config

    find "$src/src" -name '*.o' -delete
    local sdl_config="$work/arm-linux-gnueabihf-sdl-config"
    cat >"$sdl_config" <<'EOF'
#!/bin/sh
exec sdl-config "$@" | sed 's|/usr/lib/x86_64-linux-gnu|/usr/lib/arm-linux-gnueabihf|g'
EOF
    chmod +x "$sdl_config"

    make -C "$src/src" -j"$JOBS" \
        CC=arm-linux-gnueabihf-gcc \
        CXX=arm-linux-gnueabihf-g++ \
        STRIP=arm-linux-gnueabihf-strip \
        SDL_CONFIG="$sdl_config"

    local pkg="$work/pkgroot"
    mkdir -p "$pkg/usr/local/bin" "$pkg/usr/local/share/doc/goattracker"
    install -m0755 "$src/linux/goattrk2" "$pkg/usr/local/bin/goattracker"
    install -m0644 "$src/debian/copyright" "$pkg/usr/local/share/doc/goattracker/copyright"
    [ -f "$src/readme.txt" ] && install -m0644 "$src/readme.txt" "$pkg/usr/local/share/doc/goattracker/readme.txt"

    make_tcz goattracker "$pkg"
    cat >"$OUT_DIR/goattracker.tcz.dep" <<'EOF'
SDL.tcz
gcc_libs.tcz
EOF
    stage_info \
        goattracker \
        "${GOATTRACKER_VERSION%-1}" \
        "GPL-2-or-later" \
        "https://cadaver.github.io/tools.html" \
        "C64 music editor" \
        "                SDL.tcz, gcc_libs.tcz" \
        "                Source: Debian goattracker $GOATTRACKER_VERSION, cross-built for armhf."
    file "$pkg/usr/local/bin/goattracker"
}

build_sunvox() {
    echo ">> packaging sunvox.tcz from official SunVox $SUNVOX_VERSION Linux ARM release"
    install_common_tools
    apt_install unzip wget

    local work="$WORK_DIR/sunvox"
    local archive="$work/sunvox-$SUNVOX_VERSION.zip"
    local src="$work/src/sunvox"
    local pkg="$work/pkgroot"
    rm -rf "$work"
    mkdir -p "$work"

    download_file "$SUNVOX_URL" "$archive" "$SUNVOX_SHA256"
    unzip -q "$archive" -d "$work/src"

    [ -x "$src/sunvox/linux_arm/sunvox" ] || {
        echo "ERROR: SunVox Linux ARM binary not found in $SUNVOX_URL" >&2
        exit 1
    }
    [ -x "$src/sunvox/linux_arm/sunvox_lofi" ] || {
        echo "ERROR: SunVox Linux ARM lofi binary not found in $SUNVOX_URL" >&2
        exit 1
    }

    mkdir -p "$pkg/usr/local/bin" "$pkg/usr/local/lib/sunvox" \
        "$pkg/usr/local/share/sunvox" "$pkg/usr/local/share/doc/sunvox"

    install -m0755 "$src/sunvox/linux_arm/sunvox" "$pkg/usr/local/lib/sunvox/sunvox"
    install -m0755 "$src/sunvox/linux_arm/sunvox_lofi" "$pkg/usr/local/lib/sunvox/sunvox-lofi"
    cp -a "$src/curves" "$src/instruments" "$src/effects" "$src/docs" \
        "$pkg/usr/local/lib/sunvox/"
    install -m0644 "$src/docs/license/sunvox.txt" "$pkg/usr/local/share/doc/sunvox/sunvox.txt"
    install -m0644 "$src/docs/changelog.txt" "$pkg/usr/local/share/doc/sunvox/changelog.txt"
    find "$pkg/usr/local/lib/sunvox" "$pkg/usr/local/share/doc/sunvox" -type d -exec chmod 0755 {} +
    find "$pkg/usr/local/lib/sunvox" "$pkg/usr/local/share/doc/sunvox" -type f -exec chmod 0644 {} +
    chmod 0755 "$pkg/usr/local/lib/sunvox/sunvox" "$pkg/usr/local/lib/sunvox/sunvox-lofi"

    cat >"$pkg/usr/local/share/sunvox/sunvox_config.pocketchip.ini" <<'EOF'
audiodriver alsa
width 480
height 272
fullscreen
softrender
touchcontrol
maxfps 20
scale 180
fscale 180
ppi 120
no_scopes
no_levels
EOF

    cat >"$pkg/usr/local/bin/sunvox" <<'EOF'
#!/bin/sh
set -eu

SUNVOX_DIR=${SUNVOX_DIR:-/usr/local/lib/sunvox}
HOME=${HOME:-/home/chip}
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/SunVox
CONFIG=$CONFIG_DIR/sunvox_config.ini

mkdir -p "$CONFIG_DIR" 2>/dev/null || true
if [ ! -f "$CONFIG" ] && [ -f /usr/local/share/sunvox/sunvox_config.pocketchip.ini ]; then
	cp /usr/local/share/sunvox/sunvox_config.pocketchip.ini "$CONFIG" 2>/dev/null || true
fi

cd "$SUNVOX_DIR"
exec "$SUNVOX_DIR/sunvox" "$@"
EOF
    chmod 0755 "$pkg/usr/local/bin/sunvox"

    cat >"$pkg/usr/local/bin/sunvox-lofi" <<'EOF'
#!/bin/sh
set -eu

SUNVOX_DIR=${SUNVOX_DIR:-/usr/local/lib/sunvox}
HOME=${HOME:-/home/chip}
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/SunVox
CONFIG=$CONFIG_DIR/sunvox_config.ini

mkdir -p "$CONFIG_DIR" 2>/dev/null || true
if [ ! -f "$CONFIG" ] && [ -f /usr/local/share/sunvox/sunvox_config.pocketchip.ini ]; then
	cp /usr/local/share/sunvox/sunvox_config.pocketchip.ini "$CONFIG" 2>/dev/null || true
fi

cd "$SUNVOX_DIR"
exec "$SUNVOX_DIR/sunvox-lofi" "$@"
EOF
    chmod 0755 "$pkg/usr/local/bin/sunvox-lofi"

    make_tcz sunvox "$pkg"
    cat >"$OUT_DIR/sunvox.tcz.dep" <<'EOF'
sdl2.tcz
gcc_libs.tcz
libasound.tcz
Xlibs.tcz
EOF
    stage_info \
        sunvox \
        "$SUNVOX_VERSION" \
        "Freeware; redistribution allowed" \
        "https://warmplace.ru/soft/sunvox/" \
        "Modular music studio with bundled instruments and effects" \
        "                sdl2.tcz, gcc_libs.tcz, libasound.tcz, Xlibs.tcz" \
        "                Source: official SunVox $SUNVOX_VERSION Linux ARM release. Includes non-OpenGL and lofi ARM binaries plus bundled instruments, effects, curves, and docs."
    file "$pkg/usr/local/lib/sunvox/sunvox" "$pkg/usr/local/lib/sunvox/sunvox-lofi"
}

write_warmplace_deps() {
    local name=$1
    cat >"$OUT_DIR/$name.tcz.dep" <<'EOF'
sdl2.tcz
gcc_libs.tcz
libasound.tcz
Xlibs.tcz
EOF
}

write_boot_pixicode_wrapper() {
    local pkg=$1 command=$2 app_dir=$3
    cat >"$pkg/usr/local/bin/$command" <<EOF
#!/bin/sh
set -eu

APP_DIR=$app_dir
CONFIG_HOME=\${XDG_CONFIG_HOME:-\${HOME:-/home/chip}/.config}
CONFIG_DIR=\$CONFIG_HOME/Pixilang
if [ -f "\$APP_DIR/bin/pixilang_config.ini" ]; then
	mkdir -p "\$CONFIG_DIR"
	cp "\$APP_DIR/bin/pixilang_config.ini" "\$CONFIG_DIR/pixilang_config.ini" 2>/dev/null || true
fi
cd "\$APP_DIR"
exec "\$APP_DIR/bin/pixilang" boot.pixicode "\$@"
EOF
    chmod 0755 "$pkg/usr/local/bin/$command"
}

write_pocket_pixilang_config() {
    local file=$1 window_name=$2 extra=${3:-}
    cat >"$file" <<EOF
windowname "$window_name"
audiodriver alsa
width 480
height 272
fullscreen
softrender
touchcontrol
maxfps 20
scale 180
fscale 180
ppi 120
buffer 1024
EOF
    if [ -n "$extra" ]; then
        printf '%s\n' "$extra" >>"$file"
    fi
}

build_warmplace_boot_pixicode_app() {
    local name=$1 version=$2 url=$3 sha256=$4 root_dir=$5 command=$6 window_name=$7 site=$8 description=$9 license=${10} info=${11} extra_config=${12:-}
    echo ">> packaging $name.tcz from official WarmPlace $version Linux ARM release"
    install_common_tools
    apt_install unzip wget

    local work="$WORK_DIR/$name"
    local archive="$work/$name-$version.zip"
    local src="$work/src/$root_dir"
    local pkg="$work/pkgroot"
    local app_dir="/usr/local/lib/$name"
    local app_root="$pkg$app_dir"
    rm -rf "$work"
    mkdir -p "$work"

    download_file "$url" "$archive" "$sha256"
    unzip -q "$archive" -d "$work/src"

    [ -x "$src/bin/pixilang_linux_arm_armhf" ] || {
        echo "ERROR: $name Linux ARM hard-float Pixilang binary not found in $url" >&2
        exit 1
    }
    [ -f "$src/boot.pixicode" ] || {
        echo "ERROR: $name boot.pixicode not found in $url" >&2
        exit 1
    }

    mkdir -p "$pkg/usr/local/bin" "$app_root/bin" "$pkg/usr/local/share/doc/$name"
    cp -a "$src/." "$app_root/"
    rm -rf \
        "$app_root/START_MACOS.app" \
        "$app_root"/START_WINDOWS* \
        "$app_root"/START_LINUX_* \
        "$app_root/bin/pixilang_linux_arm64" \
        "$app_root/bin/pixilang_linux_x86" \
        "$app_root/bin/pixilang_linux_x86_64"
    install -m0755 "$src/bin/pixilang_linux_arm_armhf" "$app_root/bin/pixilang"
    rm -f "$app_root/bin/pixilang_linux_arm_armhf"
    write_pocket_pixilang_config "$app_root/bin/pixilang_config.ini" "$window_name" "$extra_config"
    [ -d "$app_root/docs" ] && cp -a "$app_root/docs/." "$pkg/usr/local/share/doc/$name/"
    find "$app_root" "$pkg/usr/local/share/doc/$name" -type d -exec chmod 0755 {} +
    find "$app_root" "$pkg/usr/local/share/doc/$name" -type f -exec chmod 0644 {} +
    chmod 0755 "$app_root/bin/pixilang"

    write_boot_pixicode_wrapper "$pkg" "$command" "$app_dir"
    make_tcz "$name" "$pkg"
    write_warmplace_deps "$name"
    stage_info \
        "$name" \
        "$version" \
        "$license" \
        "$site" \
        "$description" \
        "                sdl2.tcz, gcc_libs.tcz, libasound.tcz, Xlibs.tcz" \
        "$info"
    file "$app_root/bin/pixilang"
}

build_virtual_ans() {
    build_warmplace_boot_pixicode_app \
        virtual-ans \
        "$VIRTUAL_ANS_VERSION" \
        "$VIRTUAL_ANS_URL" \
        "$VIRTUAL_ANS_SHA256" \
        virtual_ans3 \
        virtual-ans \
        "Virtual ANS" \
        "https://warmplace.ru/soft/ans/" \
        "Spectral synthesizer based on drawing sound as images" \
        "Freeware; redistribution allowed" \
        "                Source: official Virtual ANS $VIRTUAL_ANS_VERSION Linux ARM release. Includes bundled projects, synth examples, resources, and docs." \
        "pixi_containers_num 65536"
}

build_pixitracker() {
    build_warmplace_boot_pixicode_app \
        pixitracker \
        "$PIXITRACKER_VERSION" \
        "$PIXITRACKER_URL" \
        "$PIXITRACKER_SHA256" \
        pixitracker \
        pixitracker \
        "PixiTracker" \
        "https://warmplace.ru/soft/pixitracker/" \
        "Pattern-based sampler/tracker for quick music sketches" \
        "Freeware; redistribution allowed" \
        "                Source: official PixiTracker $PIXITRACKER_VERSION 16Bit Linux ARM release. Includes sound packs, example songs, resources, and docs."
}

build_pixitracker_1bit() {
    build_warmplace_boot_pixicode_app \
        pixitracker-1bit \
        "$PIXITRACKER_VERSION" \
        "$PIXITRACKER_1BIT_URL" \
        "$PIXITRACKER_1BIT_SHA256" \
        pixitracker_1bit \
        pixitracker-1bit \
        "PixiTracker 1BIT" \
        "https://warmplace.ru/soft/pixitracker/" \
        "Retro 1-bit variant of PixiTracker" \
        "Freeware; redistribution allowed" \
        "                Source: official PixiTracker 1Bit $PIXITRACKER_VERSION Linux ARM release. Includes sound packs, example songs, resources, and docs."
}

build_pixilang() {
    echo ">> packaging pixilang.tcz from official Pixilang $PIXILANG_VERSION Linux ARM release"
    install_common_tools
    apt_install unzip wget

    local work="$WORK_DIR/pixilang"
    local archive="$work/pixilang-$PIXILANG_VERSION.zip"
    local src="$work/src/pixilang/pixilang3"
    local pkg="$work/pkgroot"
    local app_dir=/usr/local/lib/pixilang
    local app_root="$pkg$app_dir"
    rm -rf "$work"
    mkdir -p "$work"

    download_file "$PIXILANG_URL" "$archive" "$PIXILANG_SHA256"
    unzip -q "$archive" -d "$work/src"

    [ -x "$src/bin/linux_arm/pixilang_no_opengl" ] || {
        echo "ERROR: Pixilang Linux ARM no-OpenGL binary not found in $PIXILANG_URL" >&2
        exit 1
    }

    mkdir -p "$pkg/usr/local/bin" "$app_root/bin" "$pkg/usr/local/share/doc/pixilang"
    install -m0755 "$src/bin/linux_arm/pixilang_no_opengl" "$app_root/bin/pixilang"
    cp -a "$src/docs" "$src/examples" "$src/lib" "$app_root/"
    write_pocket_pixilang_config "$app_root/bin/pixilang_config.ini" "Pixilang"
    cp -a "$src/docs/." "$pkg/usr/local/share/doc/pixilang/"
    find "$app_root" "$pkg/usr/local/share/doc/pixilang" -type d -exec chmod 0755 {} +
    find "$app_root" "$pkg/usr/local/share/doc/pixilang" -type f -exec chmod 0644 {} +
    chmod 0755 "$app_root/bin/pixilang"

    cat >"$pkg/usr/local/bin/pixilang" <<EOF
#!/bin/sh
set -eu

PIXILANG_DIR=$app_dir
CONFIG_HOME=\${XDG_CONFIG_HOME:-\${HOME:-/home/chip}/.config}
CONFIG_DIR=\$CONFIG_HOME/Pixilang
if [ -f "\$PIXILANG_DIR/bin/pixilang_config.ini" ]; then
	mkdir -p "\$CONFIG_DIR"
	cp "\$PIXILANG_DIR/bin/pixilang_config.ini" "\$CONFIG_DIR/pixilang_config.ini" 2>/dev/null || true
fi
if [ "\$#" = 0 ]; then
	cd "\$PIXILANG_DIR/examples/graphics"
	exec "\$PIXILANG_DIR/bin/pixilang" generator_plasma.pixi
fi
exec "\$PIXILANG_DIR/bin/pixilang" "\$@"
EOF
    chmod 0755 "$pkg/usr/local/bin/pixilang"

    make_tcz pixilang "$pkg"
    write_warmplace_deps pixilang
    stage_info \
        pixilang \
        "$PIXILANG_VERSION" \
        "MIT" \
        "https://warmplace.ru/soft/pixilang/" \
        "Small graphics and sound programming language with MIDI and audio examples" \
        "                sdl2.tcz, gcc_libs.tcz, libasound.tcz, Xlibs.tcz" \
        "                Source: official Pixilang $PIXILANG_VERSION Linux ARM release. The PocketCHIP package uses the no-OpenGL ARM binary and includes docs, examples, and libraries."
    file "$app_root/bin/pixilang"
}

write_tic80_toolchain() {
    local file=$1
    cat >"$file" <<'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)
set(CMAKE_FIND_ROOT_PATH /usr/arm-linux-gnueabihf)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

write_armhf_toolchain() {
    local file=$1
    cat >"$file" <<'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)
set(CMAKE_FIND_ROOT_PATH /usr/arm-linux-gnueabihf)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

build_tic80() {
    echo ">> building tic80.tcz from TIC-80 $TIC80_TAG"
    install_common_tools
    apt_install git cmake ninja-build pkg-config python3 ruby rake \
        libcurl4-openssl-dev:armhf libgl-dev:armhf libglu1-mesa-dev:armhf \
        libegl-dev:armhf libgles-dev:armhf libasound2-dev:armhf \
        libx11-dev:armhf libxcursor-dev:armhf libxext-dev:armhf \
        libxi-dev:armhf libxinerama-dev:armhf libxrandr-dev:armhf \
        libxrender-dev:armhf libxss-dev:armhf libxtst-dev:armhf \
        libxkbcommon-dev:armhf

    local work="$WORK_DIR/tic80"
    local src="$work/src"
    local build="$work/build"
    rm -rf "$work"
    mkdir -p "$work"
    git clone --recursive --branch "$TIC80_TAG" --depth 1 https://github.com/nesbox/TIC-80.git "$src"
    require_pinned_commit "$src" "$TIC80_COMMIT" "TIC-80 $TIC80_TAG"

    # PocketCHIP has hardware arrow keys and numbered keys beside the screen.
    # Make game prompts intuitive: 1 is TIC-80 A, 2 is TIC-80 B.
    perl -0pi -e 's/SDL_SCANCODE_Z,\n\s*SDL_SCANCODE_X,/SDL_SCANCODE_1,\n                    SDL_SCANCODE_2,/g' \
        "$src/src/system/sdl/main.c"

    local toolchain="$work/armhf-toolchain.cmake"
    write_tic80_toolchain "$toolchain"

    export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
    export PKG_CONFIG_PATH=

    local curl_lib="" curl_include=""
    for candidate in /usr/lib/arm-linux-gnueabihf/libcurl.so /usr/lib/arm-linux-gnueabihf/libcurl.so.*; do
        if [ -e "$candidate" ]; then
            curl_lib=$candidate
            break
        fi
    done
    for candidate in /usr/include/arm-linux-gnueabihf /usr/include; do
        if [ -f "$candidate/curl/curl.h" ]; then
            curl_include=$candidate
            break
        fi
    done
    [ -n "$curl_lib" ] || { echo "ERROR: armhf libcurl was not found" >&2; exit 1; }
    [ -n "$curl_include" ] || { echo "ERROR: armhf curl headers were not found" >&2; exit 1; }

    local xlib_dir=/usr/lib/arm-linux-gnueabihf
    for candidate in libX11.so libXext.so libXcursor.so libXi.so libXfixes.so libXrandr.so libXrender.so libXss.so; do
        [ -e "$xlib_dir/$candidate" ] || { echo "ERROR: armhf $candidate was not found" >&2; exit 1; }
    done
    for candidate in X11/Xlib.h X11/extensions/Xext.h X11/extensions/XInput2.h; do
        [ -f "/usr/include/$candidate" ] || { echo "ERROR: $candidate was not found" >&2; exit 1; }
    done

    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCURL_LIBRARY="$curl_lib" \
        -DCURL_INCLUDE_DIR="$curl_include" \
        -DX_INCLUDEDIR=/usr/include \
        -DX11_LIB="$xlib_dir/libX11.so" \
        -DXEXT_LIB="$xlib_dir/libXext.so" \
        -DXCURSOR_LIB="$xlib_dir/libXcursor.so" \
        -DXI_LIB="$xlib_dir/libXi.so" \
        -DXFIXES_LIB="$xlib_dir/libXfixes.so" \
        -DXRANDR_LIB="$xlib_dir/libXrandr.so" \
        -DXRENDER_LIB="$xlib_dir/libXrender.so" \
        -DXSS_LIB="$xlib_dir/libXss.so" \
        -DBUILD_SDL=On \
        -DBUILD_SDLGPU=On \
        -DBUILD_SOKOL=Off \
        -DBUILD_LIBRETRO=Off \
        -DBUILD_DEMO_CARTS=Off \
        -DBUILD_PLAYER=Off \
        -DBUILD_PRO=Off \
        -DBUILD_TOUCH_INPUT=On \
        -DBUILD_WITH_MRUBY=Off \
        -DBUILD_WITH_JANET=Off \
        -DSDL_ALSA=On \
        -DSDL_ARTS=Off \
        -DSDL_DBUS=Off \
        -DSDL_ESD=Off \
        -DSDL_HIDAPI=Off \
        -DSDL_IBUS=Off \
        -DSDL_JACK=Off \
        -DSDL_KMSDRM=Off \
        -DSDL_LIBSAMPLERATE=Off \
        -DSDL_NAS=Off \
        -DSDL_PIPEWIRE=Off \
        -DSDL_PULSEAUDIO=Off \
        -DSDL_RPI=Off \
        -DSDL_SNDIO=Off \
        -DSDL_VIVANTE=Off \
        -DSDL_VULKAN=Off \
        -DSDL_WAYLAND=Off \
        -DSDL_X11=On \
        -DSDL_X11_SHARED=On
    cmake --build "$build" --target tic80 --parallel "$JOBS"

    local pkg="$work/pkgroot"
    mkdir -p "$pkg/usr/local/bin" "$pkg/usr/local/share/doc/tic80" \
        "$pkg/usr/local/share/applications" "$pkg/usr/local/share/pixmaps"
    install -m0755 "$build/bin/tic80" "$pkg/usr/local/bin/tic80"
    [ -f "$src/LICENSE" ] && install -m0644 "$src/LICENSE" "$pkg/usr/local/share/doc/tic80/LICENSE"
    [ -f "$src/build/linux/tic80.desktop" ] && install -m0644 "$src/build/linux/tic80.desktop" "$pkg/usr/local/share/applications/tic80.desktop"
    [ -f "$src/build/linux/tic80.png" ] && install -m0644 "$src/build/linux/tic80.png" "$pkg/usr/local/share/pixmaps/tic80.png"

    make_tcz tic80 "$pkg"
    cat >"$OUT_DIR/tic80.tcz.dep" <<'EOF'
curl.tcz
gcc_libs.tcz
libasound.tcz
mesa.tcz
Xlibs.tcz
EOF
    stage_info \
        tic80 \
        "${TIC80_TAG#v}" \
        "MIT" \
        "https://github.com/nesbox/TIC-80" \
        "Tiny fantasy computer" \
        "                curl.tcz, gcc_libs.tcz, libasound.tcz, mesa.tcz, Xlibs.tcz" \
        "                Source: upstream TIC-80 $TIC80_TAG, X11/ALSA SDLGPU build, armhf cross-compiled."
    file "$pkg/usr/local/bin/tic80"
}

build_mgba() {
    echo ">> building mgba.tcz from mGBA $MGBA_TAG"
    install_common_tools
    apt_install git cmake ninja-build pkg-config libsdl1.2-dev:armhf libpixman-1-dev:armhf

    local work="$WORK_DIR/mgba"
    local src="$work/src"
    local build="$work/build"
    rm -rf "$work"
    mkdir -p "$work"
    git clone --recursive --branch "$MGBA_TAG" --depth 1 https://github.com/mgba-emu/mgba.git "$src"
    require_pinned_commit "$src" "$MGBA_COMMIT" "mGBA $MGBA_TAG"

    # Xfbdev on PocketCHIP can expose a hardware/double-buffered SDL 1.2
    # surface that opens but never visibly updates. Force a software surface.
    perl -0pi -e 's/SDL_DOUBLEBUF \| SDL_HWSURFACE/SDL_SWSURFACE/g' \
        "$src/src/platform/sdl/sw-sdl1.c"
    # Match the PocketCHIP game controls used by TIC-80: arrows, 1=A, 2=B.
    perl -0pi -e 's/SDLK_x, GBA_KEY_A/SDLK_1, GBA_KEY_A/g; s/SDLK_z, GBA_KEY_B/SDLK_2, GBA_KEY_B/g' \
        "$src/src/platform/sdl/sdl-events.c"
    # SDL 1.2 software output otherwise draws the native Game Boy/GBA
    # framebuffer at 0,0 when fullscreen is larger than the game viewport.
    # Scale to the largest aspect-correct rectangle and center it.
    cat >"$src/src/platform/sdl/sw-sdl1.c" <<'EOF'
/* Copyright (c) 2013-2015 Jeffrey Pfau
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
#include "main.h"

#include <mgba/core/core.h>
#include <mgba/core/thread.h>
#include <mgba/core/version.h>

#include <string.h>

static bool mSDLSWInit(struct mSDLRenderer* renderer);
static void mSDLSWRunloop(struct mSDLRenderer* renderer, void* user);
static void mSDLSWDeinit(struct mSDLRenderer* renderer);

static bool mSDLSWIsPocketQuitKey(const SDL_Event* event) {
	if (event->type != SDL_KEYDOWN) {
		return false;
	}
	switch (event->key.keysym.sym) {
	case SDLK_HOME:
	case SDLK_POWER:
		return true;
	default:
		break;
	}
	/* SDL 1.2 can leave XF86 keys as SDLK_UNKNOWN; keep the X keycodes too. */
	switch (event->key.keysym.scancode) {
	case 110: /* Home */
	case 124: /* XF86PowerOff */
	case 180: /* XF86HomePage */
		return true;
	default:
		return false;
	}
}

#ifdef USE_PIXMAN
static void mSDLSWGetDrawRect(struct mSDLRenderer* renderer, unsigned width, unsigned height,
    int* drawX, int* drawY, int* drawWidth, int* drawHeight) {
	*drawX = 0;
	*drawY = 0;
	*drawWidth = renderer->viewportWidth;
	*drawHeight = renderer->viewportHeight;

	if (!renderer->lockAspectRatio || !width || !height || renderer->viewportWidth <= 0 || renderer->viewportHeight <= 0) {
		return;
	}

	if (renderer->lockIntegerScaling) {
		unsigned scaleX = renderer->viewportWidth / width;
		unsigned scaleY = renderer->viewportHeight / height;
		unsigned scale = scaleX < scaleY ? scaleX : scaleY;
		if (scale < 1) {
			scale = 1;
		}
		*drawWidth = width * scale;
		*drawHeight = height * scale;
	} else if ((uint64_t) renderer->viewportWidth * height > (uint64_t) renderer->viewportHeight * width) {
		*drawHeight = renderer->viewportHeight;
		*drawWidth = ((uint64_t) renderer->viewportHeight * width) / height;
	} else {
		*drawWidth = renderer->viewportWidth;
		*drawHeight = ((uint64_t) renderer->viewportWidth * height) / width;
	}

	*drawX = (renderer->viewportWidth - *drawWidth) / 2;
	*drawY = (renderer->viewportHeight - *drawHeight) / 2;
}
#endif

void mSDLSWCreate(struct mSDLRenderer* renderer) {
	renderer->init = mSDLSWInit;
	renderer->deinit = mSDLSWDeinit;
	renderer->runloop = mSDLSWRunloop;
}

bool mSDLSWInit(struct mSDLRenderer* renderer) {
	unsigned width, height;
	renderer->core->desiredVideoDimensions(renderer->core, &width, &height);
	renderer->viewportWidth = 480;
	renderer->viewportHeight = 272;
	renderer->player.fullscreen = true;
#ifdef COLOR_16_BIT
	SDL_SetVideoMode(renderer->viewportWidth, renderer->viewportHeight, 16, SDL_SWSURFACE | (SDL_FULLSCREEN * renderer->player.fullscreen));
#else
	SDL_SetVideoMode(renderer->viewportWidth, renderer->viewportHeight, 32, SDL_SWSURFACE | (SDL_FULLSCREEN * renderer->player.fullscreen));
#endif
	SDL_WM_SetCaption(projectName, "");

	SDL_Surface* surface = SDL_GetVideoSurface();
	SDL_LockSurface(surface);

	if (renderer->ratio == 1 && width == (unsigned) renderer->viewportWidth && height == (unsigned) renderer->viewportHeight) {
		renderer->core->setVideoBuffer(renderer->core, surface->pixels, surface->pitch / BYTES_PER_PIXEL);
	} else {
#ifdef USE_PIXMAN
		renderer->outputBuffer = malloc(width * height * BYTES_PER_PIXEL);
		renderer->core->setVideoBuffer(renderer->core, renderer->outputBuffer, width);
#ifdef COLOR_16_BIT
#ifdef COLOR_5_6_5
		pixman_format_code_t format = PIXMAN_r5g6b5;
#else
		pixman_format_code_t format = PIXMAN_x1b5g5r5;
#endif
#else
		pixman_format_code_t format = PIXMAN_x8b8g8r8;
#endif
		renderer->pix = pixman_image_create_bits(format, width, height,
		    renderer->outputBuffer, width * BYTES_PER_PIXEL);
		renderer->screenpix = pixman_image_create_bits(format, renderer->viewportWidth, renderer->viewportHeight, surface->pixels, surface->pitch);

		pixman_image_set_filter(renderer->pix, PIXMAN_FILTER_NEAREST, 0, 0);
#else
		return false;
#endif
	}

	return true;
}

void mSDLSWRunloop(struct mSDLRenderer* renderer, void* user) {
	struct mCoreThread* context = user;
	SDL_Event event;
	SDL_Surface* surface = SDL_GetVideoSurface();

	while (mCoreThreadIsActive(context)) {
		while (SDL_PollEvent(&event)) {
			if (mSDLSWIsPocketQuitKey(&event)) {
				mCoreThreadEnd(context);
				continue;
			}
			mSDLHandleEvent(context, &renderer->player, &event);
		}

		if (mCoreSyncWaitFrameStart(&context->impl->sync)) {
#ifdef USE_PIXMAN
			if (renderer->outputBuffer) {
				unsigned width, height;
				int drawX, drawY, drawWidth, drawHeight;
				renderer->core->desiredVideoDimensions(renderer->core, &width, &height);
				mSDLSWGetDrawRect(renderer, width, height, &drawX, &drawY, &drawWidth, &drawHeight);
				memset(surface->pixels, 0, surface->pitch * renderer->viewportHeight);
				for (int dy = 0; dy < drawHeight; ++dy) {
					unsigned sy = ((uint64_t) dy * height) / drawHeight;
					color_t* src = &renderer->outputBuffer[sy * width];
					color_t* dst = (color_t*) ((uint8_t*) surface->pixels + (drawY + dy) * surface->pitch) + drawX;
					for (int dx = 0; dx < drawWidth; ++dx) {
						unsigned sx = ((uint64_t) dx * width) / drawWidth;
						dst[dx] = src[sx];
					}
				}
			}
#else
			if (renderer->ratio != 1) {
				abort();
			}
#endif
			SDL_UnlockSurface(surface);
			SDL_Flip(surface);
			SDL_LockSurface(surface);
		}
		mCoreSyncWaitFrameEnd(&context->impl->sync);
	}
}

void mSDLSWDeinit(struct mSDLRenderer* renderer) {
	if (renderer->outputBuffer) {
		free(renderer->outputBuffer);
#ifdef USE_PIXMAN
		pixman_image_unref(renderer->pix);
		pixman_image_unref(renderer->screenpix);
#endif
	}
	SDL_Surface* surface = SDL_GetVideoSurface();
	SDL_UnlockSurface(surface);
}
EOF

    local toolchain="$work/armhf-toolchain.cmake"
    write_armhf_toolchain "$toolchain"

    export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
    export PKG_CONFIG_PATH=

    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_SKIP_RPATH=ON \
        -DSDL_VERSION=1.2 \
        -DSDL_INCLUDE_DIR=/usr/include/SDL \
        -DSDL_LIBRARY_TEMP=/usr/lib/arm-linux-gnueabihf/libSDL.so \
        -DSDL_LIBRARY=/usr/lib/arm-linux-gnueabihf/libSDL.so \
        -DBUILD_QT=OFF \
        -DBUILD_SDL=ON \
        -DBUILD_LIBRETRO=OFF \
        -DBUILD_PERF=OFF \
        -DBUILD_TEST=OFF \
        -DBUILD_SUITE=OFF \
        -DBUILD_CINEMA=OFF \
        -DBUILD_ROM_TEST=OFF \
        -DBUILD_EXAMPLE=OFF \
        -DBUILD_PYTHON=OFF \
        -DBUILD_UPDATER=OFF \
        -DBUILD_STATIC=ON \
        -DBUILD_SHARED=OFF \
        -DBUILD_GL=OFF \
        -DBUILD_GLES2=OFF \
        -DBUILD_GLES3=OFF \
        -DUSE_DEBUGGERS=OFF \
        -DUSE_GDB_STUB=OFF \
        -DUSE_DISCORD_RPC=OFF \
        -DENABLE_SCRIPTING=OFF \
        -DUSE_FFMPEG=OFF \
        -DUSE_EDITLINE=OFF \
        -DUSE_EPOXY=OFF \
        -DUSE_LIBZIP=OFF \
        -DUSE_MINIZIP=OFF \
        -DUSE_SQLITE3=OFF \
        -DUSE_ELF=OFF \
        -DUSE_LUA=OFF \
        -DUSE_LZMA=OFF \
        -DUSE_PNG=OFF \
        -DUSE_ZLIB=OFF
    cmake --build "$build" --target mgba-sdl --parallel "$JOBS"

    local pkg="$work/pkgroot"
    mkdir -p "$pkg/usr/local/bin" "$pkg/usr/local/share/doc/mgba"
    install -m0755 "$build/sdl/mgba" "$pkg/usr/local/bin/mgba"
    arm-linux-gnueabihf-strip --strip-unneeded "$pkg/usr/local/bin/mgba"
    install -m0644 "$src/LICENSE" "$pkg/usr/local/share/doc/mgba/LICENSE"
    [ -f "$src/README.md" ] && install -m0644 "$src/README.md" "$pkg/usr/local/share/doc/mgba/README.md"

    make_tcz mgba "$pkg"
    cat >"$OUT_DIR/mgba.tcz.dep" <<'EOF'
SDL.tcz
pixman.tcz
gcc_libs.tcz
EOF
    stage_info \
        mgba \
        "$MGBA_TAG" \
        "MPL-2.0" \
        "https://mgba.io/" \
        "Game Boy, Game Boy Color, and Game Boy Advance emulator" \
        "                SDL.tcz, pixman.tcz, gcc_libs.tcz" \
        "                Source: upstream mGBA $MGBA_TAG, SDL 1.2 software-rendered armhf build without ZIP/debug/scripting support."
    file "$pkg/usr/local/bin/mgba"
}

build_doom() {
    local chocolate_version=${CHOCOLATE_DOOM_TAG#chocolate-doom-}
    echo ">> building doom.tcz from Chocolate Doom $chocolate_version and Freedoom $FREEDOOM_VERSION"
    install_common_tools
    apt_install git autoconf automake libtool pkg-config unzip wget \
        libsdl2-dev:armhf libsdl2-mixer-dev:armhf libsdl2-net-dev:armhf \
        libsamplerate0-dev:armhf

    local work="$WORK_DIR/doom"
    local src="$work/chocolate-doom"
    local pkg="$work/pkgroot"
    local freedoom_zip="$work/freedoom-$FREEDOOM_VERSION.zip"
    local freedoom_dir="$work/freedoom"
    rm -rf "$work"
    mkdir -p "$work"
    git clone --depth 1 --branch "$CHOCOLATE_DOOM_TAG" \
        https://github.com/chocolate-doom/chocolate-doom.git "$src"
    require_pinned_commit "$src" "$CHOCOLATE_DOOM_COMMIT" "Chocolate Doom $CHOCOLATE_DOOM_TAG"

    (
        cd "$src"
        autoreconf -fi
        export PKG_CONFIG=pkg-config
        export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
        export PKG_CONFIG_SYSROOT_DIR=/
        ./configure --host=arm-linux-gnueabihf --prefix=/usr/local --disable-silent-rules
        make -j"$JOBS"
    )

    download_file "https://github.com/freedoom/freedoom/releases/download/v$FREEDOOM_VERSION/freedoom-$FREEDOOM_VERSION.zip" "$freedoom_zip" "$FREEDOOM_SHA256"
    mkdir -p "$freedoom_dir"
    unzip -q "$freedoom_zip" -d "$freedoom_dir"

    mkdir -p "$pkg/usr/local/bin" \
        "$pkg/usr/local/share/doom" \
        "$pkg/usr/local/share/doc/doom/chocolate-doom" \
        "$pkg/usr/local/share/doc/doom/freedoom"
    install -m0755 "$src/src/chocolate-doom" "$pkg/usr/local/bin/chocolate-doom"
    arm-linux-gnueabihf-strip --strip-unneeded "$pkg/usr/local/bin/chocolate-doom"
    install -m0644 "$freedoom_dir/freedoom-$FREEDOOM_VERSION/freedoom1.wad" \
        "$pkg/usr/local/share/doom/freedoom1.wad"
    [ -f "$src/COPYING.md" ] && install -m0644 "$src/COPYING.md" "$pkg/usr/local/share/doc/doom/chocolate-doom/COPYING.md"
    [ -f "$src/README.md" ] && install -m0644 "$src/README.md" "$pkg/usr/local/share/doc/doom/chocolate-doom/README.md"
    install -m0644 "$freedoom_dir/freedoom-$FREEDOOM_VERSION/COPYING.txt" "$pkg/usr/local/share/doc/doom/freedoom/COPYING.txt"
    install -m0644 "$freedoom_dir/freedoom-$FREEDOOM_VERSION/CREDITS.txt" "$pkg/usr/local/share/doc/doom/freedoom/CREDITS.txt"

    make_tcz doom "$pkg"
    cat >"$OUT_DIR/doom.tcz.dep" <<'EOF'
sdl2.tcz
sdl2_mixer.tcz
sdl2_net.tcz
libsamplerate.tcz
gcc_libs.tcz
EOF
    stage_info \
        doom \
        "$chocolate_version + freedoom-$FREEDOOM_VERSION" \
        "GPL-2-or-later and BSD-3-Clause assets" \
        "https://www.chocolate-doom.org/ https://freedoom.github.io/" \
        "Chocolate Doom with the free Freedoom Phase 1 IWAD" \
        "                sdl2.tcz, sdl2_mixer.tcz, sdl2_net.tcz, libsamplerate.tcz, gcc_libs.tcz" \
        "                Source: upstream Chocolate Doom $CHOCOLATE_DOOM_TAG and Freedoom $FREEDOOM_VERSION. Only freedoom1.wad is included to keep the extension small."
    file "$pkg/usr/local/bin/chocolate-doom"
}

for app in "${apps[@]}"; do
    case "$app" in
        goattracker) build_goattracker ;;
        sunvox) build_sunvox ;;
        virtual-ans) build_virtual_ans ;;
        pixitracker) build_pixitracker ;;
        pixitracker-1bit) build_pixitracker_1bit ;;
        pixilang) build_pixilang ;;
        tic80) build_tic80 ;;
        mgba) build_mgba ;;
        doom) build_doom ;;
        all) build_goattracker; build_sunvox; build_pixitracker; build_pixitracker_1bit; build_pixilang; build_tic80; build_mgba; build_doom ;;
        *) echo "ERROR: unknown app '$app' (expected goattracker, sunvox, virtual-ans, pixitracker, pixitracker-1bit, pixilang, tic80, mgba, doom, or all)" >&2; exit 2 ;;
    esac
done

echo ">> community extensions written to $OUT_DIR"
