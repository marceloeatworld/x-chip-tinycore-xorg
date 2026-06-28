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
TIC80_TAG=${TIC80_TAG:-v1.1.2837}
MGBA_TAG=${MGBA_TAG:-0.10.5}
CHOCOLATE_DOOM_TAG=${CHOCOLATE_DOOM_TAG:-chocolate-doom-3.1.1}
FREEDOOM_VERSION=${FREEDOOM_VERSION:-0.13.0}
JOBS=${JOBS:-$(nproc)}

apps=("$@")
if [ "${#apps[@]}" = 0 ]; then
    apps=(goattracker tic80 mgba doom)
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

    # Xfbdev on PocketCHIP can expose a hardware/double-buffered SDL 1.2
    # surface that opens but never visibly updates. Force a software surface.
    perl -0pi -e 's/SDL_DOUBLEBUF \| SDL_HWSURFACE/SDL_SWSURFACE/g' \
        "$src/src/platform/sdl/sw-sdl1.c"

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

    (
        cd "$src"
        autoreconf -fi
        export PKG_CONFIG=pkg-config
        export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
        export PKG_CONFIG_SYSROOT_DIR=/
        ./configure --host=arm-linux-gnueabihf --prefix=/usr/local --disable-silent-rules
        make -j"$JOBS"
    )

    wget -q -O "$freedoom_zip" \
        "https://github.com/freedoom/freedoom/releases/download/v$FREEDOOM_VERSION/freedoom-$FREEDOOM_VERSION.zip"
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
        tic80) build_tic80 ;;
        mgba) build_mgba ;;
        doom) build_doom ;;
        all) build_goattracker; build_tic80; build_mgba; build_doom ;;
        *) echo "ERROR: unknown app '$app' (expected goattracker, tic80, mgba, doom, or all)" >&2; exit 2 ;;
    esac
done

echo ">> community extensions written to $OUT_DIR"
