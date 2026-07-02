#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
source ./config.env
if [ "${PUBLIC_IMAGE:-0}" != 1 ] && [ -f "$SECRETS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS_ENV"
fi

if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    REQUIRE_WIFI_CONFIG=0
    REQUIRE_AUTHORIZED_KEYS=0
    SSH_PASSWORD_AUTH=1
fi

if [ -z "${SSH_PASSWORD_AUTH:-}" ]; then
    if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 0 ]; then
        SSH_PASSWORD_AUTH=1
    else
        SSH_PASSWORD_AUTH=0
    fi
fi
case "$SSH_PASSWORD_AUTH" in
    0|1) ;;
    *) echo "ERROR: SSH_PASSWORD_AUTH must be 0 or 1" >&2; exit 1 ;;
esac

ROOTFS=${1:-${ROOTFS:-$OUT}}

[ -f "$ROOTFS" ] || {
    echo "missing rootfs: $ROOTFS" >&2
    exit 1
}

TMP_LIST=$(mktemp)
TMP_VERBOSE=$(mktemp)
TMP_ROOT=$(mktemp -d)
trap 'rm -f "$TMP_LIST" "$TMP_VERBOSE"; rm -rf "$TMP_ROOT"' EXIT
tar -tzf "$ROOTFS" >"$TMP_LIST"
tar -tvzf "$ROOTFS" >"$TMP_VERBOSE"
tar --exclude='./dev/*' --exclude='dev/*' -xzf "$ROOTFS" -C "$TMP_ROOT"

has_entry() {
    local path=${1#/}
    grep -qxF "$path" "$TMP_LIST" || \
        grep -qxF "./$path" "$TMP_LIST" || \
        grep -qxF "$path/" "$TMP_LIST" || \
        grep -qxF "./$path/" "$TMP_LIST"
}

require_entry() {
    has_entry "$1" || {
        echo "ERROR: rootfs is missing /${1#/}" >&2
        exit 1
    }
}

extract_entry() {
    local path=${1#/}
    cat "$TMP_ROOT/$path"
}

tar_verbose_line() {
    local path=${1#/}
    awk -v path="$path" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == path || $i == "./" path || $i == path "/" || $i == "./" path "/") {
                    print
                    found = 1
                    exit
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$TMP_VERBOSE"
}

require_owner() {
    local path=$1 expected=$2 line owner
    line=$(tar_verbose_line "$path") || {
        echo "ERROR: rootfs is missing /${path#/}" >&2
        exit 1
    }
    owner=$(printf '%s\n' "$line" | awk '{print $2}')
    [ "$owner" = "$expected" ] || {
        echo "ERROR: /${path#/} owner is $owner, expected $expected" >&2
        exit 1
    }
}

require_mode_pattern() {
    local path=$1 pattern=$2 line mode
    line=$(tar_verbose_line "$path") || {
        echo "ERROR: rootfs is missing /${path#/}" >&2
        exit 1
    }
    mode=$(printf '%s\n' "$line" | awk '{print $1}')
    case "$mode" in
        $pattern) ;;
        *)
            echo "ERROR: /${path#/} mode is $mode, expected $pattern" >&2
            exit 1
            ;;
    esac
}

require_type() {
    local path=$1 expected=$2 line mode actual
    line=$(tar_verbose_line "$path") || {
        echo "ERROR: rootfs is missing /${path#/}" >&2
        exit 1
    }
    mode=$(printf '%s\n' "$line" | awk '{print $1}')
    actual=${mode:0:1}
    [ "$actual" = "$expected" ] || {
        echo "ERROR: /${path#/} archive type is $actual, expected $expected" >&2
        exit 1
    }
}

require_nonempty() {
    local bytes
    require_entry "$1"
    bytes=$(extract_entry "$1" | wc -c)
    [ "$bytes" -gt 0 ] || {
        echo "ERROR: rootfs has empty /${1#/}" >&2
        exit 1
    }
}

require_empty() {
    local bytes
    require_entry "$1"
    bytes=$(extract_entry "$1" | wc -c)
    [ "$bytes" -eq 0 ] || {
        echo "ERROR: rootfs has non-empty /${1#/}" >&2
        exit 1
    }
}

reject_entry() {
    has_entry "$1" && {
        echo "ERROR: rootfs contains forbidden /${1#/}" >&2
        exit 1
    }
    return 0
}

require_content() {
    local path=$1 pattern=$2
    require_entry "$path"
    extract_entry "$path" | grep -aF -- "$pattern" >/dev/null || {
        echo "ERROR: /${path#/} does not contain expected marker: $pattern" >&2
        exit 1
    }
}

require_binary_hex() {
    local path=$1 pattern=$2 note=$3 hex
    require_entry "$path"
    hex=$(extract_entry "$path" | od -An -tx1 | tr -d ' \n')
    case "$hex" in
        *"$pattern"*) ;;
        *)
            echo "ERROR: /${path#/} missing expected binary marker: $note" >&2
            exit 1
            ;;
    esac
}

reject_binary_hex() {
    local path=$1 pattern=$2 note=$3 hex
    require_entry "$path"
    hex=$(extract_entry "$path" | od -An -tx1 | tr -d ' \n')
    case "$hex" in
        *"$pattern"*)
            echo "ERROR: /${path#/} contains forbidden binary marker: $note" >&2
            exit 1
            ;;
    esac
}

require_xpm_icon() {
    local path=$1 header
    require_entry "$path"
    header=$(extract_entry "$path" | sed -n 's/^"\([0-9][^"]*\)",$/\1/p' | head -n 1)
    [ "$header" = "16 16 5 1" ] || {
        echo "ERROR: /${path#/} XPM header is '$header', expected '16 16 5 1'" >&2
        exit 1
    }
    require_content "$path" '#0F1716'
    require_content "$path" '#1F7A66'
    require_content "$path" '#EAF2EF'
    require_content "$path" '#6A7A75'
}

reject_content() {
    local path=$1 pattern=$2
    require_entry "$path"
    if extract_entry "$path" | grep -aF -- "$pattern" >/dev/null; then
        echo "ERROR: /${path#/} contains unsupported marker: $pattern" >&2
        exit 1
    fi
}

require_shell_syntax() {
    local path=$1 tmp
    local -a shell_check
    require_entry "$path"
    tmp=$(mktemp)
    extract_entry "$path" >"$tmp"
    if command -v busybox >/dev/null 2>&1; then
        shell_check=(busybox ash -n)
    elif command -v dash >/dev/null 2>&1; then
        shell_check=(dash -n)
    else
        shell_check=(sh -n)
    fi
    if ! "${shell_check[@]}" "$tmp"; then
        echo "ERROR: /${path#/} has invalid shell syntax" >&2
        rm -f "$tmp"
        exit 1
    fi
    rm -f "$tmp"
}

require_loginable_shadow() {
    local password_field
    password_field=$(extract_entry etc/shadow | awk -F: -v user="$SSH_USER" '$1 == user { print $2; found = 1 } END { exit found ? 0 : 1 }') || {
        echo "ERROR: /etc/shadow has no $SSH_USER entry" >&2
        exit 1
    }
    case "$password_field" in
        ""|\!*|\**)
            echo "ERROR: /etc/shadow password for $SSH_USER is locked or empty" >&2
            exit 1
            ;;
    esac
}

reject_locked_shadow() {
    local password_field
    password_field=$(extract_entry etc/shadow | awk -F: -v user="$SSH_USER" '$1 == user { print $2; found = 1 } END { exit found ? 0 : 1 }') || {
        echo "ERROR: /etc/shadow has no $SSH_USER entry" >&2
        exit 1
    }
    case "$password_field" in
        \!*|\**)
            echo "ERROR: /etc/shadow password for $SSH_USER is locked; key-only SSH needs an unlocked account" >&2
            exit 1
            ;;
    esac
}

require_order() {
    local path=$1 first=$2 second=$3 first_line second_line
    require_entry "$path"
    first_line=$(extract_entry "$path" | grep -a -n "$first" | head -n 1 | cut -d: -f1)
    second_line=$(extract_entry "$path" | grep -a -n "$second" | head -n 1 | cut -d: -f1)
    if [ -z "$first_line" ] || [ -z "$second_line" ] || [ "$first_line" -ge "$second_line" ]; then
        echo "ERROR: /${path#/} must run '$first' before '$second'" >&2
        exit 1
    fi
}

require_pocketchip_keymap_complete() {
    local tmp normal_prefix special_prefix
    tmp=$(mktemp)
    extract_entry usr/share/kmap/pocketchip.kmap >"$tmp"
    normal_prefix=$(od -An -tx1 -j264 -N16 "$tmp" | tr -d ' \n')
    [ "$normal_prefix" = "021b0031003200330034003500360037" ] || {
        echo "ERROR: /usr/share/kmap/pocketchip.kmap is missing normal US key entries" >&2
        rm -f "$tmp"
        exit 1
    }
    special_prefix=$(od -An -tx1 -j816 -N10 "$tmp" | tr -d ' \n')
    [ "$special_prefix" = "0b7b007d005b005d007c" ] || {
        echo "ERROR: /usr/share/kmap/pocketchip.kmap is missing Fn/AltGr special entries" >&2
        rm -f "$tmp"
        exit 1
    }
    rm -f "$tmp"
}

for required in \
    bin/busybox \
    sbin/init \
    init \
    etc/inittab \
    etc/fstab \
    etc/init.d/rcS \
    etc/init.d/tc-config \
    etc/udev/rules.d/98-tc.rules \
    etc/os-release \
    etc/issue \
    etc/motd \
    etc/modprobe.d/8812au.conf \
    etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules \
    boot/zImage \
    boot/boot.scr \
    boot/sun5i-r8-chip.dtb \
    dev/console \
    dev/null \
    dev/tty \
    dev/tty0 \
    dev/tty1 \
    dev/ttyS0 \
    dev/net/tun \
    opt/x-chip-boot.sh \
    opt/x-chip-autologin.sh \
    opt/x-chip-tty1-getty.sh \
    opt/x-chip-early-debug.sh \
    usr/local/bin/x-chip-keyboard-status \
    usr/local/bin/x-chip-audio-status \
    usr/local/bin/x-chip-power-status \
    usr/local/bin/x-chip-term-hold \
    usr/local/bin/x-chip-mc \
    usr/local/bin/x-chip-status \
    usr/local/bin/x-chip-calc \
    usr/local/bin/x-chip-time \
    usr/local/bin/x-chip-open \
    usr/local/bin/x-chip-open-image \
    usr/local/bin/x-chip-open-pdf \
    usr/local/bin/x-chip-music \
    usr/local/bin/x-chip-video \
    usr/local/bin/xdg-open \
    usr/local/bin/x-chip-tic80 \
    usr/local/bin/x-chip-goattracker \
    usr/local/bin/x-chip-sunvox \
    usr/local/bin/x-chip-virtual-ans \
    usr/local/bin/x-chip-pixitracker \
    usr/local/bin/x-chip-pixitracker-1bit \
    usr/local/bin/x-chip-pixilang \
    usr/local/bin/x-chip-mgba \
    usr/local/bin/x-chip-pico8 \
    usr/local/bin/x-chip-games \
    usr/local/bin/x-chip-doom \
    usr/local/bin/x-chip-desktop-stats \
    usr/local/bin/x-chip-logs \
    usr/local/bin/x-chip-brightness \
    usr/local/bin/x-chip-wifi-menu \
    usr/local/bin/x-chip-media-on \
    usr/local/bin/x-chip-startx \
    usr/local/bin/x-chip-desktop-start \
    usr/local/bin/x-chip-gtk-cache \
    usr/local/bin/x-chip-close-app \
    usr/local/bin/x-chip-close-game \
    usr/local/bin/x-chip-game-launch \
    usr/local/bin/x-chip-x-apply-calibration \
    usr/local/bin/x-chip-x-keymap \
    usr/local/bin/x-chip-touch-calibrate \
    usr/local/bin/x-chip-xorg-launch-vt \
    usr/local/bin/x-chip-xorg-session \
    usr/local/bin/Xorg \
    usr/local/lib/xorg/Xorg \
    usr/local/lib/xorg/Xorg.wrap \
    usr/local/lib/xorg/modules/drivers/fbdev_drv.so \
    usr/local/lib/xorg/modules/input/libinput_drv.so \
    usr/local/bin/jwm \
    usr/local/bin/aterm \
    usr/local/bin/xrandr \
    usr/local/bin/xinput \
    usr/local/sbin/sshd \
    usr/local/share/x-chip/materialized-tcz.lst \
    usr/local/bin/iw \
    usr/local/bin/iwconfig \
    usr/local/bin/wpa_cli \
    usr/local/bin/x-chip-load-rtl8812au \
    usr/local/sbin/x-chip-rtl8812au-hotplug \
    usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf \
    etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf \
    usr/local/etc/x-chip/display.conf \
    usr/local/etc/x-chip/desktop.conf \
    usr/local/etc/x-chip/wifi.conf \
    usr/local/share/x-chip/xorg/touchscreen-calibration.matrix \
    usr/local/share/x-chip/xorg/jwmrc \
    usr/local/share/x-chip/xorg/mc.ini \
    usr/local/share/mc/skins/pocketclean256.ini \
    usr/local/share/x-chip/xorg/wallpapers/pocket-core.png \
    usr/local/share/x-chip/xorg/Xdefaults \
    usr/local/share/x-chip/xorg/mc-media.ext.ini \
    usr/local/share/applications/x-chip-image.desktop \
    usr/local/share/applications/x-chip-video.desktop \
    usr/local/share/applications/x-chip-music.desktop \
    usr/local/share/applications/x-chip-pdf.desktop \
    usr/local/share/applications/x-chip-text.desktop \
    usr/local/share/applications/mimeapps.list \
    usr/local/share/applications/mimeinfo.cache \
    usr/local/share/mime/mime.cache \
    usr/local/share/x-chip/xorg/icons/apps.xpm \
    usr/local/share/x-chip/xorg/icons/back.xpm \
    usr/local/share/x-chip/xorg/icons/brightness.xpm \
    usr/local/share/x-chip/xorg/icons/browser.xpm \
    usr/local/share/x-chip/xorg/icons/close.xpm \
    usr/local/share/x-chip/xorg/icons/code.xpm \
    usr/local/share/x-chip/xorg/icons/editor.xpm \
    usr/local/share/x-chip/xorg/icons/file.xpm \
    usr/local/share/x-chip/xorg/icons/files.xpm \
    usr/local/share/x-chip/xorg/icons/forward.xpm \
    usr/local/share/x-chip/xorg/icons/home.xpm \
    usr/local/share/x-chip/xorg/icons/image.xpm \
    usr/local/share/x-chip/xorg/icons/menu.xpm \
    usr/local/share/x-chip/xorg/icons/monitor.xpm \
    usr/local/share/x-chip/xorg/icons/network.xpm \
    usr/local/share/x-chip/xorg/icons/pocket.xpm \
    usr/local/share/x-chip/xorg/icons/refresh.xpm \
    usr/local/share/x-chip/xorg/icons/terminal.xpm \
    usr/local/share/x-chip/xorg/icons/touch.xpm \
    usr/local/share/x-chip/xorg/icons/up.xpm \
    usr/local/share/x-chip/xorg/icons/window.xpm \
    usr/local/share/icons/x-chip/index.theme \
    usr/local/share/icons/x-chip/16x16/actions/go-previous.xpm \
    usr/local/share/icons/x-chip/16x16/actions/go-next.xpm \
    usr/local/share/icons/x-chip/16x16/actions/go-up.xpm \
    usr/local/share/icons/x-chip/16x16/actions/go-home.xpm \
    usr/local/share/icons/x-chip/16x16/actions/view-refresh.xpm \
    usr/local/share/icons/x-chip/16x16/actions/document-new.xpm \
    usr/local/share/icons/x-chip/16x16/actions/document-open.xpm \
    usr/local/share/icons/x-chip/16x16/actions/document-save.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-copy.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-paste.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-undo.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-redo.xpm \
    usr/local/share/icons/x-chip/16x16/apps/pcmanfm.xpm \
    usr/local/share/icons/x-chip/16x16/apps/geany.xpm \
    usr/local/share/icons/x-chip/16x16/places/folder.xpm \
    usr/local/share/icons/x-chip/16x16/places/user-home.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/text-x-generic.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/application-pdf.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/audio-x-generic.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/video-x-generic.xpm \
    usr/local/share/x-chip/xorg/geany.conf \
    usr/local/share/x-chip/xorg/leafpadrc \
    usr/local/share/x-chip/xorg/pcmanfm.conf \
    usr/local/share/x-chip/xorg/dillorc \
    usr/local/share/x-chip/xorg/gtkrc-2.0 \
    usr/local/share/x-chip/xorg/gtk3-settings.ini \
    usr/local/share/x-chip/xorg/Xdefaults \
    usr/local/share/x-chip/tic80-carts.tsv \
    usr/local/share/x-chip/gameboy-homebrew.tsv \
    usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example \
    usr/local/etc/ssh/sshd_config \
    home/$SSH_USER/Pictures \
    home/$SSH_USER/Videos \
    home/$SSH_USER/Music \
    home/$SSH_USER/Downloads \
    home/$SSH_USER/Games/GameBoy \
    home/$SSH_USER/Pictures/red-hood-field.jpeg \
    home/$SSH_USER/Videos/pocket-video-demo.mp4 \
    home/$SSH_USER/Videos/night-lamp-dream.mp4 \
    home/$SSH_USER/Music/dreamscape-sample.mp3 \
    usr/share/kmap/pocketchip.kmap \
    usr/share/kmap/pocketchip.loadkeys \
    lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo \
    lib/firmware/nextthingco/chip/early/x-chip-pocketchip-v72.dtbo \
    lib/firmware/nextthingco/chip/early/x-chip-dip-hdmi-popcorn.dtbo \
    lib/firmware/rtlwifi/rtl8723bs_nic.bin \
    tce/onboot.lst \
    tce/media.lst \
    tce/xorg.lst; do
    require_entry "$required"
done

for root_owned in \
    bin/busybox \
    bin/busybox.suid \
    sbin/init \
    sbin/getty \
    usr/bin/sudo \
    etc/passwd \
    etc/group \
    etc/shadow \
    etc/inittab \
    etc/init.d/tc-config \
    boot/zImage \
    boot/boot.scr \
    boot/sun5i-r8-chip.dtb \
    opt/x-chip-boot.sh \
    opt/x-chip-autologin.sh \
    opt/x-chip-tty1-getty.sh \
    usr/local/bin/x-chip-keyboard-status \
    usr/local/bin/x-chip-audio-status \
    usr/local/bin/x-chip-power-status \
    usr/local/bin/x-chip-term-hold \
    usr/local/bin/x-chip-status \
    usr/local/bin/x-chip-calc \
    usr/local/bin/x-chip-time \
    usr/local/bin/x-chip-open \
    usr/local/bin/x-chip-open-image \
    usr/local/bin/x-chip-open-pdf \
    usr/local/bin/x-chip-music \
    usr/local/bin/x-chip-video \
    usr/local/bin/xdg-open \
    usr/local/bin/x-chip-tic80 \
    usr/local/bin/x-chip-goattracker \
    usr/local/bin/x-chip-sunvox \
    usr/local/bin/x-chip-virtual-ans \
    usr/local/bin/x-chip-pixitracker \
    usr/local/bin/x-chip-pixitracker-1bit \
    usr/local/bin/x-chip-pixilang \
    usr/local/bin/x-chip-mgba \
    usr/local/bin/x-chip-pico8 \
    usr/local/bin/x-chip-games \
    usr/local/bin/x-chip-doom \
    usr/local/bin/x-chip-desktop-stats \
    usr/local/bin/x-chip-logs \
    usr/local/bin/x-chip-brightness \
    usr/local/bin/x-chip-wifi-menu \
    usr/local/bin/x-chip-startx \
    usr/local/bin/x-chip-desktop-start \
    usr/local/bin/x-chip-gtk-cache \
    usr/local/bin/x-chip-close-app \
    usr/local/bin/x-chip-close-game \
    usr/local/bin/x-chip-game-launch \
    usr/local/bin/x-chip-x-apply-calibration \
    usr/local/bin/x-chip-x-keymap \
    usr/local/bin/x-chip-touch-calibrate \
    usr/local/bin/x-chip-xorg-launch-vt \
    usr/local/bin/x-chip-xorg-session \
    usr/local/bin/Xorg \
    usr/local/lib/xorg/Xorg \
    usr/local/lib/xorg/Xorg.wrap \
    usr/local/lib/xorg/modules/drivers/fbdev_drv.so \
    usr/local/lib/xorg/modules/input/libinput_drv.so \
    usr/local/bin/jwm \
    usr/local/bin/aterm \
    usr/local/bin/xrandr \
    usr/local/bin/xinput \
    usr/local/sbin/sshd \
    usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf \
    etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf \
    usr/local/share/x-chip/xorg/touchscreen-calibration.matrix \
    usr/local/share/x-chip/xorg/pocketchip.xmodmap \
    usr/local/share/x-chip/xorg/jwmrc \
    usr/local/share/x-chip/xorg/wallpapers/pocket-core.png \
    usr/local/share/x-chip/xorg/icons/apps.xpm \
    usr/local/share/x-chip/xorg/icons/back.xpm \
    usr/local/share/x-chip/xorg/icons/brightness.xpm \
    usr/local/share/x-chip/xorg/icons/browser.xpm \
    usr/local/share/x-chip/xorg/icons/close.xpm \
    usr/local/share/x-chip/xorg/icons/code.xpm \
    usr/local/share/x-chip/xorg/icons/editor.xpm \
    usr/local/share/x-chip/xorg/icons/file.xpm \
    usr/local/share/x-chip/xorg/icons/files.xpm \
    usr/local/share/x-chip/xorg/icons/forward.xpm \
    usr/local/share/x-chip/xorg/icons/home.xpm \
    usr/local/share/x-chip/xorg/icons/image.xpm \
    usr/local/share/x-chip/xorg/icons/menu.xpm \
    usr/local/share/x-chip/xorg/icons/monitor.xpm \
    usr/local/share/x-chip/xorg/icons/network.xpm \
    usr/local/share/x-chip/xorg/icons/pocket.xpm \
    usr/local/share/x-chip/xorg/icons/refresh.xpm \
    usr/local/share/x-chip/xorg/icons/terminal.xpm \
    usr/local/share/x-chip/xorg/icons/touch.xpm \
    usr/local/share/x-chip/xorg/icons/up.xpm \
    usr/local/share/x-chip/xorg/icons/window.xpm \
    usr/local/share/icons/x-chip/index.theme \
    usr/local/share/icons/x-chip/16x16/actions/go-previous.xpm \
    usr/local/share/icons/x-chip/16x16/actions/go-next.xpm \
    usr/local/share/icons/x-chip/16x16/actions/go-up.xpm \
    usr/local/share/icons/x-chip/16x16/actions/go-home.xpm \
    usr/local/share/icons/x-chip/16x16/actions/view-refresh.xpm \
    usr/local/share/icons/x-chip/16x16/actions/document-new.xpm \
    usr/local/share/icons/x-chip/16x16/actions/document-open.xpm \
    usr/local/share/icons/x-chip/16x16/actions/document-save.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-copy.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-paste.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-undo.xpm \
    usr/local/share/icons/x-chip/16x16/actions/edit-redo.xpm \
    usr/local/share/icons/x-chip/16x16/apps/pcmanfm.xpm \
    usr/local/share/icons/x-chip/16x16/apps/geany.xpm \
    usr/local/share/icons/x-chip/16x16/places/folder.xpm \
    usr/local/share/icons/x-chip/16x16/places/user-home.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/text-x-generic.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/application-pdf.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/audio-x-generic.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/video-x-generic.xpm \
    usr/local/share/x-chip/xorg/geany.conf \
    usr/local/share/x-chip/xorg/leafpadrc \
    usr/local/share/x-chip/xorg/pcmanfm.conf \
    usr/local/share/x-chip/xorg/dillorc \
    usr/local/share/x-chip/xorg/gtkrc-2.0 \
    usr/local/share/x-chip/xorg/gtk3-settings.ini \
    usr/local/share/x-chip/xorg/Xdefaults \
    usr/local/share/x-chip/xorg/mc-media.ext.ini \
    usr/local/share/applications/x-chip-image.desktop \
    usr/local/share/applications/x-chip-video.desktop \
    usr/local/share/applications/x-chip-music.desktop \
    usr/local/share/applications/x-chip-pdf.desktop \
    usr/local/share/applications/x-chip-text.desktop \
    usr/local/share/applications/mimeapps.list \
    usr/local/share/applications/mimeinfo.cache \
    usr/local/share/mime/mime.cache \
    usr/local/share/x-chip/tic80-carts.tsv \
    usr/local/share/x-chip/gameboy-homebrew.tsv \
    usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example; do
    require_owner "$root_owned" "0/0"
done

require_mode_pattern bin/busybox.suid '-rws*'
require_mode_pattern usr/bin/sudo '-rws*'
require_mode_pattern etc/shadow '-rw-------'
require_mode_pattern opt/x-chip-autologin.sh '-rwx*'
require_mode_pattern opt/x-chip-tty1-getty.sh '-rwx*'
require_mode_pattern usr/local/bin/x-chip-keyboard-status '-rwx*'
require_mode_pattern usr/local/bin/x-chip-audio-status '-rwx*'
require_mode_pattern usr/local/bin/x-chip-power-status '-rwx*'
require_mode_pattern usr/local/bin/x-chip-term-hold '-rwx*'
require_mode_pattern usr/local/bin/x-chip-status '-rwx*'
require_mode_pattern usr/local/bin/x-chip-calc '-rwx*'
require_mode_pattern usr/local/bin/x-chip-time '-rwx*'
require_mode_pattern usr/local/bin/x-chip-open '-rwx*'
require_mode_pattern usr/local/bin/x-chip-open-image '-rwx*'
require_mode_pattern usr/local/bin/x-chip-open-pdf '-rwx*'
require_mode_pattern usr/local/bin/x-chip-music '-rwx*'
require_mode_pattern usr/local/bin/x-chip-video '-rwx*'
require_type usr/local/bin/xdg-open l
require_mode_pattern usr/local/bin/x-chip-tic80 '-rwx*'
require_mode_pattern usr/local/bin/x-chip-goattracker '-rwx*'
require_mode_pattern usr/local/bin/x-chip-sunvox '-rwx*'
require_mode_pattern usr/local/bin/x-chip-virtual-ans '-rwx*'
require_mode_pattern usr/local/bin/x-chip-pixitracker '-rwx*'
require_mode_pattern usr/local/bin/x-chip-pixitracker-1bit '-rwx*'
require_mode_pattern usr/local/bin/x-chip-pixilang '-rwx*'
require_mode_pattern usr/local/bin/x-chip-mgba '-rwx*'
require_mode_pattern usr/local/bin/x-chip-pico8 '-rwx*'
require_mode_pattern usr/local/bin/x-chip-games '-rwx*'
require_mode_pattern usr/local/bin/x-chip-doom '-rwx*'
require_mode_pattern usr/local/bin/x-chip-desktop-stats '-rwx*'
require_mode_pattern usr/local/bin/x-chip-logs '-rwx*'
require_mode_pattern usr/local/bin/x-chip-brightness '-rwx*'
require_mode_pattern usr/local/bin/x-chip-wifi-menu '-rwx*'
require_mode_pattern usr/local/bin/x-chip-startx '-rwx*'
require_mode_pattern usr/local/bin/x-chip-desktop-start '-rwx*'
require_mode_pattern usr/local/bin/x-chip-gtk-cache '-rwx*'
require_mode_pattern usr/local/bin/x-chip-game-launch '-rwx*'
require_mode_pattern usr/local/bin/x-chip-x-apply-calibration '-rwx*'
require_mode_pattern usr/local/bin/x-chip-x-keymap '-rwx*'
require_mode_pattern usr/local/bin/x-chip-touch-calibrate '-rwx*'
require_mode_pattern usr/local/bin/x-chip-xorg-launch-vt '-rwx*'
require_mode_pattern usr/local/bin/x-chip-xorg-session '-rwx*'
require_mode_pattern usr/local/bin/Xorg '-rwx*'
require_mode_pattern usr/local/lib/xorg/Xorg '-rws*'
require_mode_pattern usr/local/lib/xorg/Xorg.wrap '-r-s*'
require_mode_pattern usr/local/bin/jwm '-rwx*'
require_mode_pattern usr/local/bin/aterm '-rwx*'
require_mode_pattern usr/local/bin/xrandr '-rwx*'
require_mode_pattern usr/local/bin/xinput '-rwx*'
require_mode_pattern usr/local/sbin/sshd '-rwx*'
require_nonempty usr/share/kmap/pocketchip.kmap
require_nonempty usr/share/kmap/pocketchip.loadkeys

for devnode in \
    dev/console \
    dev/null \
    dev/tty \
    dev/tty0 \
    dev/tty1 \
    dev/ttyS0 \
    dev/net/tun; do
    require_type "$devnode" c
    require_owner "$devnode" "0/0"
done

require_entry "home/$SSH_USER/.ssh/authorized_keys"
require_owner "home/$SSH_USER" "$SSH_UID/$SSH_GID"
require_owner "home/$SSH_USER/.ssh" "$SSH_UID/$SSH_GID"
require_owner "home/$SSH_USER/.ssh/authorized_keys" "$SSH_UID/$SSH_GID"
require_owner "home/$SSH_USER/Games/GameBoy" "$SSH_UID/$SSH_GID"
require_mode_pattern "home/$SSH_USER/.ssh" 'drwx------'
require_mode_pattern "home/$SSH_USER/.ssh/authorized_keys" '-rw-------'
if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 1 ]; then
    require_nonempty "home/$SSH_USER/.ssh/authorized_keys"
fi
if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    require_empty "home/$SSH_USER/.ssh/authorized_keys"
    require_empty "root/.ssh/authorized_keys"
    reject_entry etc/wpa_supplicant.conf
    if awk -v user="$SSH_USER" '
        BEGIN { prefix1 = "home/" user "/Games/GameBoy/"; prefix2 = "./" prefix1 }
        {
            path = $0
            if ((index(path, prefix1) == 1 || index(path, prefix2) == 1) &&
                path ~ /\.(gb|gbc|gba|GB|GBC|GBA)$/) {
                print path
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' "$TMP_LIST" >/tmp/x-chip-public-roms.$$; then
        echo "ERROR: public image contains Game Boy ROM(s):" >&2
        cat /tmp/x-chip-public-roms.$$ >&2
        rm -f /tmp/x-chip-public-roms.$$
        exit 1
    fi
    rm -f /tmp/x-chip-public-roms.$$
fi
if [ "$SSH_PASSWORD_AUTH" = 1 ]; then
    require_loginable_shadow
else
    reject_locked_shadow
fi

# The piCore base ships a passwordless 'tc' user with NOPASSWD sudo; the
# assemble step must lock it and revoke the grant in every build.
tc_shadow_field=$(extract_entry etc/shadow | awk -F: '$1 == "tc" { print $2; found = 1 } END { if (!found) print "absent" }')
case "$tc_shadow_field" in
    absent|\!*|\**) ;;
    *)
        echo "ERROR: /etc/shadow leaves the base 'tc' account loginable" >&2
        exit 1
        ;;
esac
if extract_entry etc/sudoers | grep -Eq '^tc[[:space:]]'; then
    echo "ERROR: /etc/sudoers still grants the base 'tc' account sudo" >&2
    exit 1
fi
if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
    require_nonempty etc/wpa_supplicant.conf
fi
if [ "${RTL8812AU_BUILD:-1}" = 1 ]; then
    require_entry "lib/modules/${KERNEL_VERSION}${KERNEL_LOCALVERSION}/extra/8812au.ko"
fi

require_content boot/boot.scr 'console=ttyS0,115200'
require_content boot/boot.scr 'console=tty0'
require_content boot/boot.scr 'loglevel=7'
require_content boot/boot.scr ' base '
if extract_entry boot/boot.scr | grep -a ' quiet ' >/dev/null; then
    echo "ERROR: boot.scr unexpectedly uses quiet boot" >&2
    exit 1
fi
require_content boot/boot.scr 'video=Unknown-1:480x272e'
require_content boot/boot.scr 'video=Composite-1:d'
require_content boot/boot.scr 'x-chip-pocketchip.dtbo'
require_content boot/boot.scr 'x-chip-pocketchip-v72.dtbo'
require_content boot/boot.scr 'x-chip-dip-hdmi-popcorn.dtbo'
require_binary_hex lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo \
    '000000060000000100000008' \
    'PocketCHIP TCA8418 keyboard IRQ must be PIO G1 LEVEL_LOW'
reject_binary_hex lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo \
    '000000060000000100000002' \
    'PocketCHIP TCA8418 keyboard IRQ must not be PIO G1 EDGE_FALLING'
require_binary_hex lib/firmware/nextthingco/chip/early/x-chip-pocketchip-v72.dtbo \
    '000000060000000100000008' \
    'PocketCHIP v72 TCA8418 keyboard IRQ must be PIO G1 LEVEL_LOW'
reject_binary_hex lib/firmware/nextthingco/chip/early/x-chip-pocketchip-v72.dtbo \
    '000000060000000100000002' \
    'PocketCHIP v72 TCA8418 keyboard IRQ must not be PIO G1 EDGE_FALLING'
require_content etc/os-release 'PRETTY_NAME="PocketCHIP TinyCore'
require_content etc/os-release 'VERSION_ID=16'
require_content etc/os-release "$PROJECT_REPO_URL"
require_content etc/issue 'PocketCHIP TinyCore'
require_content etc/motd 'PocketCHIP TinyCore'
# A tmpfs hides /tmp at runtime, so anything packed under it is dead NAND
# weight the assemble step forgot to clean.
if grep -E '^(\./)?tmp/.' "$TMP_LIST" >&2; then
    echo "ERROR: packed rootfs ships files under /tmp" >&2
    exit 1
fi
require_content etc/fstab 'tmpfs           /tmp         tmpfs'
require_content etc/fstab 'tmpfs           /run         tmpfs'
require_content etc/fstab 'tmpfs           /var/run     tmpfs'
require_content etc/fstab 'tmpfs           /var/lock    tmpfs'
require_content etc/init.d/rcS '/bin/mount -a'
require_content etc/init.d/tc-config 'udevadm settle --timeout=5'
require_content etc/init.d/tc-config 'fstab_pid:-'
require_content etc/udev/rules.d/98-tc.rules 'rebuildfstab'
require_content opt/x-chip-boot.sh 'ensure_devpts'
require_content opt/x-chip-boot.sh 'ensure_runtime_dirs'
require_content opt/x-chip-boot.sh '/var/run/wpa_supplicant'
require_content opt/x-chip-boot.sh 'RUN_DIR=/dev/shm/x-chip'
require_content opt/x-chip-boot.sh 'RUN_MARKER="$RUN_DIR/boot-ran"'
require_content opt/x-chip-boot.sh 'RUN_LOCK="$RUN_DIR/boot.lock"'
require_content opt/x-chip-boot.sh 'CONSOLE_READY="$RUN_DIR/console-ready"'
require_content opt/x-chip-boot.sh 'TCE_READY="$RUN_DIR/tce-loaded"'
require_content opt/x-chip-boot.sh 'restore_clock_floor'
require_content opt/x-chip-boot.sh 'built_at_epoch'
require_content usr/local/share/x-chip/release-info 'built_at_epoch='
require_content opt/x-chip-boot.sh 'prepare_tce_runtime'
require_content opt/x-chip-boot.sh 'reset_tce_installed_markers'
require_content opt/x-chip-boot.sh 'materialized-tcz.lst'
require_content opt/x-chip-boot.sh '/usr/local/tce.installed'
require_content opt/x-chip-boot.sh 'load_tcz_boot_core'
require_content opt/x-chip-boot.sh 'load_tcz_onboot_background'
require_content opt/x-chip-boot.sh 'tce-load -il'
require_content opt/x-chip-boot.sh 'load_keymap'
require_content opt/x-chip-boot.sh 'configure_power_management'
require_content opt/x-chip-boot.sh 'load_audio_modules'
require_content opt/x-chip-boot.sh 'Power Amplifier DAC'
require_content opt/x-chip-boot.sh "Power Amplifier Mute' on"
require_content opt/x-chip-boot.sh 'LCD_BRIGHTNESS_VALUE='
require_content opt/x-chip-boot.sh 'LCD brightness set to'
require_content opt/x-chip-boot.sh 'silence_kernel_console'
require_content opt/x-chip-boot.sh 'boot_status'
require_content opt/x-chip-boot.sh 'X-CHIP TinyCore'
require_content opt/x-chip-boot.sh 'Starting desktop on VT2'

# The WiFi menu runs as the desktop user; it must escalate for iface up,
# scans, and the supplicant or it reports "No networks found".
require_content usr/local/bin/x-chip-wifi-menu 'as_root'
require_content usr/local/bin/x-chip-wifi-menu 'as_root ip link set'
require_content usr/local/bin/x-chip-wifi-menu 'as_root iw dev'

# Power controls: menu entries exist and always confirm before acting.
require_mode_pattern usr/local/bin/x-chip-shutdown '-rwxr-xr-x'
require_content usr/local/bin/x-chip-shutdown 'Type y to'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-shutdown poweroff'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-shutdown reboot'
require_content usr/local/bin/x-chip-xorg-session '.jwmrc.shipped'

# In-place update tooling must ship in every image.
require_mode_pattern usr/local/bin/x-chip-update '-rwxr-xr-x'
require_content usr/local/bin/x-chip-update 'applied-release'
require_content usr/local/bin/x-chip-update '.update.tar.gz'
require_content usr/local/bin/x-chip-update 'ensure_clock'
require_content usr/local/bin/x-chip-update 'rootfs_built_at_epoch'
require_nonempty usr/local/share/x-chip/update-repo
require_nonempty usr/local/share/x-chip/release-info
require_content opt/x-chip-boot.sh 'Boot runtime complete'
require_content opt/x-chip-boot.sh 'touch "$RUN_MARKER"'
require_content opt/x-chip-boot.sh 'touch "$CONSOLE_READY"'
require_content opt/x-chip-boot.sh 'touch "$TCE_READY"'
require_content opt/x-chip-boot.sh 'desktop not detected after launch; retrying once'
require_content opt/x-chip-boot.sh 'Desktop Xorg and window manager ready'
require_content opt/x-chip-boot.sh 'rm -rf /tmp/x-chip-firstboot-ran /tmp/x-chip-firstboot.lock'
reject_entry opt/x-chip-firstboot.sh
reject_content opt/x-chip-boot.sh 'if [ -e /tmp/x-chip-firstboot-ran'
reject_content opt/x-chip-boot.sh 'mkdir /tmp/x-chip-firstboot.lock'
reject_content opt/x-chip-boot.sh 'touch /tmp/x-chip-firstboot-ran'
reject_content opt/x-chip-boot.sh 'touch /tmp/x-chip-console-ready'
require_order opt/x-chip-boot.sh '^ensure_devpts$' '^ensure_runtime_dirs$'
require_order opt/x-chip-boot.sh '^ensure_runtime_dirs$' '^prepare_tce_runtime$'
require_order opt/x-chip-boot.sh '^silence_kernel_console$' '^touch "\$CONSOLE_READY"'
require_order opt/x-chip-boot.sh '^reset_tce_installed_markers$' '^load_tcz_boot_core$'
require_order opt/x-chip-boot.sh '^touch "\$CONSOLE_READY"' '^start_usb_debug_gadget &[[:space:]]*$'
require_order opt/x-chip-boot.sh '^start_usb_debug_gadget &[[:space:]]*$' '^load_tcz_boot_core$'
require_order opt/x-chip-boot.sh '^load_tcz_boot_core$' '^start_ssh$'
require_order opt/x-chip-boot.sh '^start_ssh$' '^load_tcz_onboot_background$'
require_order opt/x-chip-boot.sh '^load_tcz_onboot_background$' '^start_desktop$'
require_content opt/x-chip-boot.sh 'start_usb_debug_gadget'
require_content opt/x-chip-boot.sh 'start_ssh'
require_content opt/x-chip-boot.sh 'ssh.lock'
require_content opt/x-chip-boot.sh 'start_wifi'
require_content opt/x-chip-boot.sh 'sync_time_background'
require_order opt/x-chip-boot.sh '^[[:space:]]*start_wifi$' '^[[:space:]]*sync_time_background$'
require_content opt/x-chip-boot.sh 'start_desktop'
require_content opt/x-chip-boot.sh 'x-chip-desktop-start --boot'
require_content opt/x-chip-boot.sh 'RTL8812AU boot autoload disabled'
require_content opt/x-chip-boot.sh 'load_rtl8812au_if_present'
require_entry opt/bootlocal.sh
require_content opt/bootlocal.sh '/opt/x-chip-boot.sh'
require_content usr/local/sbin/x-chip-rtl8812au-hotplug 'modprobe 8812au'
require_content usr/local/sbin/x-chip-rtl8812au-hotplug 'remains the primary SSH/network adapter'
require_content etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules 'x-chip-rtl8812au-hotplug'
require_content etc/modprobe.d/8812au.conf 'options 8812au'
require_content opt/x-chip-tty1-getty.sh 'getty -n'
require_content opt/x-chip-tty1-getty.sh 'READY=/dev/shm/x-chip/console-ready'
require_content opt/x-chip-tty1-getty.sh 'WAITED'
require_content opt/x-chip-autologin.sh 'login -f'
require_content usr/local/bin/x-chip-media-on 'ffplay'
require_content usr/local/bin/x-chip-media-on 'mpg123'
require_content usr/local/bin/x-chip-media-on 'tce-load'
require_content usr/local/bin/x-chip-media-on 'x-chip-media-on.lock'
require_content usr/local/bin/x-chip-media-on 'load_tcz_one ffmpeg.tcz'
require_content usr/local/bin/x-chip-media-on 'load_tcz_one mpg123.tcz'
require_content usr/local/bin/x-chip-startx 'XORG_LIST=/tce/xorg.lst'
require_content usr/local/bin/x-chip-startx 'X_CHIP_WM'
require_content usr/local/bin/x-chip-startx 'openvt'
require_content usr/local/bin/x-chip-startx 'setsid'
require_content usr/local/bin/x-chip-startx 'chvt'
require_content usr/local/bin/x-chip-startx 'x-chip-xorg-launch-vt'
require_content usr/local/bin/x-chip-startx 'refresh_graphical_caches'
require_content usr/local/bin/x-chip-startx 'x-chip-gtk-cache quick'
require_content usr/local/bin/x-chip-startx 'x-chip-wm-recover.log'
require_content usr/local/bin/x-chip-startx 'x-chip-x-keymap'
require_content usr/local/bin/x-chip-startx 'pidof Xorg'
require_content usr/local/bin/x-chip-startx 'rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock'
require_content usr/local/bin/x-chip-startx 'prune_conflicting_xorg_defaults'
require_content usr/local/bin/x-chip-startx '/usr/local/share/X11/xorg.conf.d/20-noglamor.conf'
require_order usr/local/bin/x-chip-startx '^load_xorg_stack$' '^prune_conflicting_xorg_defaults$'
require_order usr/local/bin/x-chip-startx '^prune_conflicting_xorg_defaults$' '^refresh_graphical_caches$'
require_order usr/local/bin/x-chip-startx '^refresh_graphical_caches$' '^install_user_desktop_config$'
require_content usr/local/bin/x-chip-desktop-start 'X_CHIP_DESKTOP_AUTOSTART'
require_content usr/local/bin/x-chip-desktop-start 'x-chip-startx'
require_content usr/local/bin/x-chip-gtk-cache 'gtk-update-icon-cache'
require_content usr/local/bin/x-chip-gtk-cache 'gdk-pixbuf-query-loaders >"$tmp"'
reject_content usr/local/bin/x-chip-gtk-cache 'gdk-pixbuf-query-loaders --update-cache'
require_content usr/local/bin/x-chip-gtk-cache 'glib-compile-schemas'
require_content usr/local/bin/x-chip-gtk-cache 'update-mime-database /usr/local/share/mime'
require_content usr/local/bin/x-chip-gtk-cache 'update-desktop-database'
require_content usr/local/bin/x-chip-x-apply-calibration 'touchscreen-calibration.matrix'
require_content usr/local/bin/x-chip-x-apply-calibration 'libinput Calibration Matrix'
require_content usr/local/bin/x-chip-x-keymap 'pocketchip.xmodmap'
require_content usr/local/bin/x-chip-x-keymap 'xmodmap "$MAP"'
require_content usr/local/bin/x-chip-touch-calibrate 'xinput test-xi2'
require_content usr/local/bin/x-chip-touch-calibrate 'SAMPLES_PER_TARGET'
require_content usr/local/bin/x-chip-touch-calibrate 'TAP_TIMEOUT'
require_content usr/local/bin/x-chip-touch-calibrate 'start=$(date +%s'
require_content usr/local/bin/x-chip-touch-calibrate 'Generated by x-chip-touch-calibrate'
require_content usr/local/bin/x-chip-xorg-session 'x-chip-x-apply-calibration'
require_content usr/local/bin/x-chip-xorg-session 'x-chip-x-keymap'
require_content usr/local/bin/x-chip-xorg-session 'exec jwm'
require_content usr/local/bin/x-chip-xorg-launch-vt 'Xorg :0'
require_content usr/local/bin/x-chip-xorg-launch-vt 'vt$X_CHIP_VT'
require_content usr/local/bin/x-chip-xorg-launch-vt 'x-chip-brightness apply'
require_content usr/local/bin/x-chip-xorg-launch-vt 'XORG_SERVER_LOG=/tmp/Xorg.0.log'
require_content usr/local/bin/x-chip-xorg-launch-vt '-logfile "$XORG_SERVER_LOG"'
reject_content usr/local/bin/x-chip-xorg-launch-vt '-configdir "$EMPTY_CONFIG_DIR"'
reject_content usr/local/bin/x-chip-xorg-launch-vt 'start_ssh_if_needed'
require_content opt/x-chip-boot.sh 'DISPLAY_CONFIG=${X_CHIP_DISPLAY_CONFIG:-/usr/local/etc/x-chip/display.conf}'
require_content opt/x-chip-boot.sh 'saved_lcd_brightness'
require_content opt/x-chip-boot.sh 'brightness="$(saved_lcd_brightness 2>/dev/null || true)"'
require_content usr/local/bin/x-chip-brightness '/sys/class/backlight'
require_content usr/local/bin/x-chip-brightness 'MIN_BRIGHTNESS='
require_content usr/local/bin/x-chip-brightness 'filetool.sh -b'
require_content usr/local/bin/x-chip-power-status 'Battery:'
require_content usr/local/bin/x-chip-power-status 'label=USB'
require_content usr/local/bin/x-chip-power-status '%s: online=%s'
require_content usr/local/bin/x-chip-term-hold 'Press enter to close.'
require_content usr/local/bin/x-chip-status 'Pocket Status'
require_content usr/local/bin/x-chip-status 'ifconfig "$iface"'
require_content usr/local/bin/x-chip-calc 'bc -l'
require_content usr/local/bin/x-chip-time 'ntpd -nq'
require_content usr/local/bin/x-chip-time 'sync-background'
require_content usr/local/bin/x-chip-open 'x-chip-open-image "$target"'
require_content usr/local/bin/x-chip-open 'x-chip-video play "$target"'
require_content usr/local/bin/x-chip-open 'aterm -title Video -e x-chip-video play "$target"'
require_content usr/local/bin/x-chip-open 'aterm -title Music -e x-chip-term-hold x-chip-music play "$target"'
require_content usr/local/bin/x-chip-open 'x-chip-music play "$target"'
require_content usr/local/bin/x-chip-open 'x-chip-open-pdf "$target"'
require_content usr/local/bin/x-chip-open-image 'gpicview'
require_content usr/local/bin/x-chip-open-pdf 'No PDF viewer is installed yet.'
require_content usr/local/bin/x-chip-music 'mpg123 -C'
require_content usr/local/bin/x-chip-music 'play-bg'
require_content usr/local/bin/x-chip-music 'pkill -x ffplay'
require_content usr/local/bin/x-chip-video 'ffplay -autoexit'
require_content usr/local/bin/x-chip-video 'SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}'
require_content usr/local/bin/x-chip-video 'pocket-video-demo.mp4'
require_content usr/local/bin/x-chip-video 'pkill -x mpg123'
require_content usr/local/share/applications/x-chip-image.desktop 'MimeType=image/png;image/jpeg;image/gif;image/webp;image/x-xpixmap;'
require_content usr/local/share/applications/x-chip-image.desktop 'Icon=image-x-generic'
require_content usr/local/share/applications/x-chip-video.desktop 'MimeType=video/mp4;video/x-m4v;video/x-msvideo;video/quicktime;video/x-matroska;video/webm;video/mpeg;'
require_content usr/local/share/applications/x-chip-video.desktop 'aterm -title Video -e x-chip-video play %f'
require_content usr/local/share/applications/x-chip-video.desktop 'Icon=video-x-generic'
require_content usr/local/share/applications/x-chip-music.desktop 'aterm -title Music -e x-chip-term-hold x-chip-music play %f'
require_content usr/local/share/applications/x-chip-music.desktop 'Icon=audio-x-generic'
require_content usr/local/share/applications/x-chip-pdf.desktop 'MimeType=application/pdf;'
require_content usr/local/share/applications/x-chip-pdf.desktop 'Icon=application-pdf'
require_content usr/local/share/applications/x-chip-text.desktop 'Icon=text-x-generic'
require_content usr/local/share/applications/mimeapps.list 'image/jpeg=x-chip-image.desktop'
require_content usr/local/share/applications/mimeapps.list 'video/mp4=x-chip-video.desktop'
require_content usr/local/share/applications/mimeapps.list 'audio/mpeg=x-chip-music.desktop'
require_content usr/local/share/applications/mimeapps.list 'application/pdf=x-chip-pdf.desktop'
require_content usr/local/share/x-chip/xorg/mc-media.ext.ini 'x-chip media handlers'
require_content usr/local/share/x-chip/xorg/mc-media.ext.ini 'x-chip-open-pdf "$MC_EXT_FILENAME"'
require_nonempty home/$SSH_USER/Pictures/red-hood-field.jpeg
require_nonempty home/$SSH_USER/Videos/pocket-video-demo.mp4
require_nonempty home/$SSH_USER/Videos/night-lamp-dream.mp4
require_nonempty home/$SSH_USER/Music/dreamscape-sample.mp3
require_content usr/local/bin/x-chip-tic80 'run_tce_load /tce/optional/tic80.tcz'
require_content usr/local/bin/x-chip-tic80 'su "$TC_USER" -c "tce-load -il $target"'
require_content usr/local/bin/x-chip-tic80 'tic80-carts.tsv'
require_content usr/local/bin/x-chip-tic80 'tls_ready'
require_content usr/local/bin/x-chip-tic80 '/usr/local/etc/pki/certs/ca-bundle.crt'
require_content usr/local/bin/x-chip-tic80 'curl --retry 2 --connect-timeout 20'
require_content usr/local/bin/x-chip-tic80 'TIC80_POCKET_KEYS'
require_content usr/local/bin/x-chip-tic80 'TIC80_CONFIG_HASH=${X_CHIP_TIC80_CONFIG_HASH:-be42d6f}'
require_content usr/local/bin/x-chip-tic80 'ensure_pocketchip_tic80_keys'
require_content usr/local/bin/x-chip-tic80 'SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}'
require_content usr/local/bin/x-chip-tic80 '--fullscreen'
require_content usr/local/bin/x-chip-tic80 '--soft'
require_content usr/local/bin/x-chip-tic80 '--scale="$TIC80_SCALE"'
require_content usr/local/bin/x-chip-tic80 '--cmd=run'
require_content usr/local/bin/x-chip-tic80 'printf '\''\034\035'\'''
require_content usr/local/bin/x-chip-tic80 'WARN: failed to install'
require_content usr/local/bin/x-chip-tic80 'install_all || true'
reject_content usr/local/bin/x-chip-tic80 'tic80 --version'
require_content usr/local/bin/x-chip-goattracker 'run_tce_load /tce/optional/goattracker.tcz'
require_content usr/local/bin/x-chip-goattracker 'su "$TC_USER" -c "tce-load -il $target"'
require_content usr/local/bin/x-chip-sunvox 'run_tce_load /tce/optional/sunvox.tcz'
require_content usr/local/bin/x-chip-sunvox 'exec "$cmd" "$@"'
require_content usr/local/bin/x-chip-virtual-ans 'run_tce_load /tce/optional/virtual-ans.tcz'
require_content usr/local/bin/x-chip-virtual-ans 'exec virtual-ans "$@"'
require_content usr/local/bin/x-chip-pixitracker 'run_tce_load /tce/optional/pixitracker.tcz'
require_content usr/local/bin/x-chip-pixitracker 'exec pixitracker "$@"'
require_content usr/local/bin/x-chip-pixitracker-1bit 'run_tce_load /tce/optional/pixitracker-1bit.tcz'
require_content usr/local/bin/x-chip-pixitracker-1bit 'exec pixitracker-1bit "$@"'
require_content usr/local/bin/x-chip-pixilang 'run_tce_load /tce/optional/pixilang.tcz'
require_content usr/local/bin/x-chip-pixilang 'CONFIG_DIR=$CONFIG_HOME/Pixilang'
require_content usr/local/bin/x-chip-pixilang 'cp /usr/local/lib/pixilang/bin/pixilang_config.ini "$CONFIG_DIR/pixilang_config.ini"'
require_content usr/local/bin/x-chip-pixilang 'generator_plasma.pixi'
require_content usr/local/bin/x-chip-pixilang 'exec pixilang "$@"'
require_content usr/local/bin/x-chip-mgba 'run_tce_load /tce/optional/mgba.tcz'
require_content usr/local/bin/x-chip-mgba 'su "$TC_USER" -c "tce-load -il $target"'
require_content usr/local/bin/x-chip-mgba 'Games/GameBoy'
require_content usr/local/bin/x-chip-mgba 'gameboy-homebrew.tsv'
require_content usr/local/bin/x-chip-mgba 'mgba-sdl1'
require_content usr/local/bin/x-chip-mgba 'MGBA_POCKET_KEYS'
require_content usr/local/bin/x-chip-mgba 'MGBA_FULLSCREEN=${X_CHIP_MGBA_FULLSCREEN:-1}'
require_content usr/local/bin/x-chip-mgba 'MGBA_WIDTH=${X_CHIP_MGBA_WIDTH:-480}'
require_content usr/local/bin/x-chip-mgba 'MGBA_HEIGHT=${X_CHIP_MGBA_HEIGHT:-272}'
require_content usr/local/bin/x-chip-mgba 'MGBA_LOCK_ASPECT=${X_CHIP_MGBA_LOCK_ASPECT:-0}'
require_content usr/local/bin/x-chip-mgba 'ensure_mgba_pocket_config'
require_content usr/local/bin/x-chip-mgba 'fullscreen=%s'
require_content usr/local/bin/x-chip-mgba 'lockAspectRatio=%s'
require_content usr/local/bin/x-chip-mgba 'lockIntegerScaling=0'
require_content usr/local/bin/x-chip-mgba '[gba.input.KEY]'
require_content usr/local/bin/x-chip-mgba 'keyA=49'
require_content usr/local/bin/x-chip-mgba 'keyB=50'
require_content usr/local/bin/x-chip-mgba 'keySelect=8'
require_content usr/local/bin/x-chip-mgba 'keyStart=13'
require_content usr/local/bin/x-chip-mgba 'SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-x11}'
require_content usr/local/bin/x-chip-mgba 'SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}'
require_content usr/local/bin/x-chip-mgba '-C "width=$MGBA_WIDTH"'
require_content usr/local/bin/x-chip-mgba '-C "height=$MGBA_HEIGHT"'
require_content usr/local/bin/x-chip-mgba '-C "lockAspectRatio=$MGBA_LOCK_ASPECT"'
reject_content usr/local/bin/x-chip-mgba 'exec "$cmd" -1'
require_content usr/local/bin/x-chip-mgba 'verify_sha256'
require_content usr/local/bin/x-chip-mgba 'sha256sum "$file"'
require_content usr/local/bin/x-chip-mgba 'install_all'
require_content usr/local/bin/x-chip-mgba 'WARN: failed to install'
require_content usr/local/bin/x-chip-mgba 'install_all || true'
require_content usr/local/bin/x-chip-mgba 'play_target'
require_content usr/local/share/x-chip/gameboy-homebrew.tsv '2048'
require_content usr/local/share/x-chip/gameboy-homebrew.tsv 'https://github.com/wyattferguson/2048-gb/releases/download/v1.1/2048.gb'
require_content usr/local/share/x-chip/gameboy-homebrew.tsv 'b8b0ab5dc8159dcd83680a2796010ecf9fc8c94c2cfb9cd3ff30c1998d790aa5'
require_content usr/local/share/x-chip/gameboy-homebrew.tsv 'ucity'
require_content usr/local/share/x-chip/gameboy-homebrew.tsv 'https://github.com/AntonioND/ucity/releases/download/v1.3/ucity.gbc'
require_content usr/local/share/x-chip/gameboy-homebrew.tsv '9422ee2ca7b7ea1d46b58b2a429fff3f354dfd3e732dee1e7ae6220f148ce6e0'
grep -F -- 'SDL_SCANCODE_1' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps TIC-80 A to 1" >&2
    exit 1
}
grep -F -- 'SDL_SCANCODE_2' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps TIC-80 B to 2" >&2
    exit 1
}
grep -F -- 'SDLK_1, GBA_KEY_A' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps mGBA A to 1" >&2
    exit 1
}
grep -F -- 'SDLK_2, GBA_KEY_B' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps mGBA B to 2" >&2
    exit 1
}
grep -F -- 'case SDLK_HOME:' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps PocketCHIP Home to quit mGBA" >&2
    exit 1
}
grep -F -- 'case SDLK_POWER:' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps PocketCHIP Power to quit mGBA" >&2
    exit 1
}
grep -F -- 'case 124: /* XF86PowerOff */' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps XF86PowerOff scancode to quit mGBA" >&2
    exit 1
}
grep -F -- 'case 180: /* XF86HomePage */' scripts/09-build-community-tcz.sh >/dev/null || {
    echo "ERROR: scripts/09-build-community-tcz.sh no longer maps XF86HomePage scancode to quit mGBA" >&2
    exit 1
}
require_content usr/local/bin/x-chip-pico8 'PICO-8 is not bundled'
require_content usr/local/bin/x-chip-pico8 '-windowed 1 -width 480 -height 272'
require_content usr/local/bin/x-chip-games 'x-chip-mgba menu'
require_content usr/local/bin/x-chip-games 'x-chip-doom run'
require_content usr/local/bin/x-chip-games 'x-chip-pico8 menu'
require_content usr/local/bin/x-chip-doom 'run_tce_load /tce/optional/doom.tcz'
require_content usr/local/bin/x-chip-doom 'su "$TC_USER" -c "tce-load -il $target"'
require_content usr/local/bin/x-chip-doom 'freedoom1.wad'
require_content usr/local/bin/x-chip-doom 'SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}'
require_content usr/local/bin/x-chip-doom '-fullscreen'
require_content usr/local/bin/x-chip-doom '-nosound -nomusic'
reject_content usr/local/bin/x-chip-doom '-window -geometry 480x272'
require_content usr/local/share/x-chip/tic80-carts.tsv '8-bit-panda'
require_content usr/local/share/x-chip/tic80-carts.tsv 'https://tic80.com/cart/'
require_content usr/local/bin/x-chip-desktop-stats 'conky -c'
require_content usr/local/bin/x-chip-desktop-stats 'STATE_CONFIG=${X_CHIP_DESKTOP_STATS_CONFIG:-/usr/local/etc/x-chip/desktop-stats.conf}'
require_content usr/local/bin/x-chip-desktop-stats 'X_CHIP_DESKTOP_STATS='
require_content usr/local/bin/x-chip-desktop-stats 'filetool.sh -b'
require_content usr/local/bin/x-chip-desktop-stats 'restore_stats'
require_content usr/local/bin/x-chip-wifi-menu 'iw dev "$iface" scan'
require_content usr/local/bin/x-chip-wifi-menu 'wpa_supplicant -B'
require_content usr/local/bin/x-chip-wifi-menu 'filetool.sh -b'
require_content usr/local/bin/x-chip-wifi-menu 'ifconfig "$iface"'
require_content usr/local/bin/x-chip-wifi-menu 'CLIENT_DRIVER=rtl8723bs'
require_content usr/local/bin/x-chip-wifi-menu 'SCAN_DRIVER=rtl8812au'
require_content usr/local/bin/x-chip-wifi-menu 'find_client_wifi_iface'
require_content usr/local/bin/x-chip-wifi-menu 'find_scan_wifi_iface'
require_content usr/local/bin/x-chip-wifi-menu 'scan-external'
require_content usr/local/bin/x-chip-wifi-menu 'as_root iw dev "$iface" scan'
require_content usr/local/bin/x-chip-wifi-menu 'tmp=/tmp/x-chip-iw-scan.$$'
require_content usr/local/bin/x-chip-wifi-menu 'No external scan WiFi interface found" >&2'
require_content usr/local/bin/x-chip-wifi-menu 'No WiFi interface found" >&2'
require_content usr/local/bin/x-chip-wifi-menu 'umask 077'
require_content usr/local/bin/x-chip-logs '/opt/x-chip-boot.log'
require_content usr/local/bin/x-chip-logs '/var/log/x-chip-desktop.log'
require_content usr/local/bin/x-chip-logs '/tmp/Xorg.0.log'
require_content usr/local/etc/x-chip/display.conf 'LCD_BRIGHTNESS='
require_content usr/local/etc/x-chip/desktop.conf 'X_CHIP_DESKTOP_AUTOSTART=1'
require_content usr/local/etc/x-chip/desktop-stats.conf 'X_CHIP_DESKTOP_STATS=0'
require_content usr/local/etc/x-chip/wifi.conf 'X_CHIP_WIFI_CLIENT_DRIVER=rtl8723bs'
require_content usr/local/etc/x-chip/wifi.conf 'X_CHIP_WIFI_SCAN_DRIVER=rtl8812au'
require_content usr/local/share/x-chip/materialized-tcz.lst 'openssh.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'Xorg.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'xorg-server.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'xf86-video-fbdev.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'xf86-input-libinput.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'jwm.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'pcmanfm.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'bc.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'gpicview.tcz'
require_content usr/local/share/x-chip/materialized-tcz.lst 'conky.tcz'
require_entry usr/local/etc/ca-certificates.conf
require_content usr/local/etc/ssl/certs/ca-certificates.crt 'BEGIN CERTIFICATE'
require_type usr/local/etc/ssl/certs/ca-bundle.crt l
require_type usr/local/etc/ssl/cacert.pem l
require_type usr/local/etc/ssl/ca-bundle.crt l
require_type usr/local/etc/pki/certs/ca-bundle.crt l
require_type etc/ssl/certs l
require_content opt/.filetool.lst 'usr/local/share/x-chip/xorg/touchscreen-calibration.matrix'
require_content opt/.filetool.lst 'usr/local/etc/x-chip'
require_content opt/.filetool.lst 'opt/x-chip-boot.sh'
require_content opt/.filetool.lst 'opt/bootlocal.sh'
reject_content opt/.filetool.lst 'opt/x-chip-firstboot.sh'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-logs'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-term-hold'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-status'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-calc'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-time'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-open'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-open-image'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-open-pdf'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-music'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-video'
require_content opt/.filetool.lst 'usr/local/bin/xdg-open'
require_content opt/.filetool.lst 'usr/local/share/applications'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-tic80'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-goattracker'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-sunvox'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-virtual-ans'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-pixitracker'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-pixitracker-1bit'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-pixilang'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-mgba'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-pico8'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-games'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-doom'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-desktop-stats'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-brightness'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-wifi-menu'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-desktop-start'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-gtk-cache'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-close-app'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-close-game'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-game-launch'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-x-keymap'
require_content opt/.filetool.lst 'usr/local/share/x-chip/tic80-carts.tsv'
require_content opt/.filetool.lst 'usr/local/share/x-chip/gameboy-homebrew.tsv'
require_content opt/.filetool.lst 'usr/local/share/x-chip/xorg/pocketchip.xmodmap'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'Driver "fbdev"'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'AutoBindGPU'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'MatchProduct "1c25000.rtp"'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'CalibrationMatrix'
require_content etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'Driver "fbdev"'
require_content etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'CalibrationMatrix'
reject_entry usr/local/share/X11/xorg.conf.d/20-noglamor.conf
reject_entry etc/X11/xorg.conf.d/20-noglamor.conf
require_entry usr/local/share/X11/xorg.conf.d/40-libinput.conf
require_content usr/local/share/x-chip/xorg/touchscreen-calibration.matrix '-1.069801149 0.001502438'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf '-1.069801149 0.001502438'
require_content usr/local/share/x-chip/xorg/jwmrc '<Tray'
require_content usr/local/share/x-chip/xorg/jwmrc '<IconPath>/usr/local/share/x-chip/xorg/icons</IconPath>'
require_content usr/local/share/x-chip/xorg/jwmrc '<DefaultIcon>pocket.xpm</DefaultIcon>'
require_content usr/local/share/x-chip/xorg/jwmrc '<StartupCommand>x-chip-x-apply-calibration</StartupCommand>'
require_content usr/local/share/x-chip/xorg/jwmrc '<StartupCommand>x-chip-x-keymap</StartupCommand>'
require_content usr/local/share/x-chip/xorg/jwmrc '<StartupCommand>x-chip-desktop-stats restore</StartupCommand>'
require_content usr/local/share/x-chip/xorg/jwmrc '<RestartCommand>x-chip-x-apply-calibration</RestartCommand>'
require_content usr/local/share/x-chip/xorg/jwmrc '<RestartCommand>x-chip-x-keymap</RestartCommand>'
require_content usr/local/share/x-chip/xorg/pocketchip.xmodmap 'keycode 108 = Mode_switch'
require_content usr/local/share/x-chip/xorg/pocketchip.xmodmap 'keycode 10 = 1 exclam F1 F1'
require_content usr/local/share/x-chip/xorg/pocketchip.xmodmap 'keycode 29 = y Y braceleft braceleft'
require_content usr/local/share/x-chip/xorg/pocketchip.xmodmap 'keycode 61 = slash question backslash backslash'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Menu" icon="menu.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Play" icon="pocket.xpm" popup="Games"'
require_content usr/local/share/x-chip/xorg/jwmrc '<TaskList maxwidth="160"/>'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Browser" icon="browser.xpm">dillo -g 474x212+0+0'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Files" icon="files.xpm">pcmanfm'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Editor" icon="editor.xpm">leafpad'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Code" icon="code.xpm">geany -s -m -p -t'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Calculator" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'links -ssl.builtin-certificates 1 https://search.brave.com/'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Images" icon="image.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Music" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Music Player" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="SunVox" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="PixiTracker" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="PixiTracker 1Bit" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Pixilang" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Video" icon="monitor.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Games" icon="apps.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Game Launcher" icon="apps.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Doom" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-doom run'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Game Boy Launcher" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-mgba'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-game-launch x-chip-mgba play 2048'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-game-launch x-chip-mgba play ucity'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="PICO-8" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-pico8 menu'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-games'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-game-launch x-chip-tic80 run'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-game-launch x-chip-tic80 play 8-bit-panda'
reject_content usr/local/share/x-chip/xorg/jwmrc '<Program label="TIC-80" icon="pocket.xpm">x-chip-tic80 run</Program>'
reject_content usr/local/share/x-chip/xorg/jwmrc '<Program label="8 Bit Panda" icon="pocket.xpm">x-chip-tic80 play 8-bit-panda</Program>'
reject_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-tic80 run'
reject_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-tic80 play'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-goattracker'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-sunvox'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-pixitracker'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-pixitracker-1bit'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-pixilang'
reject_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-virtual-ans'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Apps" icon="apps.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Network" icon="network.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Brightness" icon="brightness.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Window" icon="window.xpm"'
require_content usr/local/share/x-chip/xorg/icons/menu.xpm 'static char *menu_xpm'
require_content usr/local/share/x-chip/xorg/icons/terminal.xpm 'static char *terminal_xpm'
require_content usr/local/share/x-chip/xorg/icons/files.xpm 'static char *files_xpm'
for icon in \
    apps back brightness browser close code editor file files forward home image menu \
    monitor network pocket refresh terminal touch up window; do
    require_xpm_icon "usr/local/share/x-chip/xorg/icons/$icon.xpm"
done
require_content usr/local/share/icons/x-chip/index.theme 'Name=X-CHIP'
require_content usr/local/share/icons/x-chip/index.theme 'Directories=16x16/actions,16x16/apps'
require_content usr/local/share/icons/x-chip/16x16/places/folder.xpm 'static char *files_xpm'
require_content usr/local/share/icons/x-chip/16x16/actions/go-home.xpm 'static char *home_xpm'
for icon_path in \
    actions/go-previous \
    actions/go-next \
    actions/go-up \
    actions/go-home \
    actions/go-jump \
    actions/view-refresh \
    actions/document-new \
    actions/document-open \
    actions/document-save \
    actions/gtk-close \
    actions/gtk-new \
    actions/gtk-open \
    actions/gtk-save \
    actions/gtk-go-back \
    actions/gtk-go-forward \
    actions/gtk-go-up \
    actions/gtk-home \
    actions/gtk-refresh \
    actions/gtk-stop \
    actions/gtk-jump-to \
    actions/gtk-directory \
    actions/gtk-file \
    actions/gtk-harddisk \
    actions/edit-copy \
    actions/edit-paste \
    actions/edit-undo \
    actions/edit-redo \
    actions/gtk-copy \
    actions/gtk-cut \
    actions/gtk-paste \
    actions/gtk-delete \
    actions/gtk-undo \
    actions/gtk-redo \
    actions/gtk-find \
    actions/gtk-add \
    actions/gtk-remove \
    apps/pcmanfm \
    apps/geany \
    places/folder \
    places/user-home \
    mimetypes/text-x-generic \
    mimetypes/application-pdf \
    mimetypes/audio-x-generic \
    mimetypes/video-x-generic \
    status/image-missing \
    status/gtk-missing-image; do
    require_xpm_icon "usr/local/share/icons/x-chip/16x16/$icon_path.xpm"
done
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-wifi-menu'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-wifi-menu status'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-wifi-menu interfaces'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-term-hold x-chip-wifi-menu scan-external'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Status" icon="monitor.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-status'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Time" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-time sync'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Desktop Stats" icon="monitor.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-desktop-stats off'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-brightness'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-logs'
require_content usr/local/share/x-chip/xorg/jwmrc 'Close Apps'
require_content usr/local/share/x-chip/xorg/jwmrc 'Close Games'
require_content usr/local/share/x-chip/xorg/jwmrc '<Key mask="A" key="F4">close</Key>'
require_content usr/local/share/x-chip/xorg/jwmrc '<Key key="Home">exec:x-chip-close-game</Key>'
require_content usr/local/share/x-chip/xorg/jwmrc '<Key key="XF86HomePage">exec:x-chip-close-game</Key>'
require_content usr/local/share/x-chip/xorg/jwmrc '<Key key="XF86PowerOff">exec:x-chip-close-game</Key>'
require_content usr/local/share/x-chip/xorg/jwmrc 'Apply Calibration'
require_content usr/local/share/x-chip/xorg/jwmrc '<Font>Luxi Sans-9</Font>'
require_content usr/local/share/x-chip/xorg/jwmrc 'Background type="image">/usr/local/share/x-chip/xorg/wallpapers/pocket-core.png'
require_content usr/local/share/x-chip/xorg/geany.conf 'pref_toolbar_show=false'
require_content usr/local/share/x-chip/xorg/geany.conf 'msgwindow_visible=false'
require_content usr/local/share/x-chip/xorg/geany.conf 'geometry=0;0;474;212;0;'
require_content usr/local/share/x-chip/xorg/geany.conf 'editor_font=Luxi Mono 9'
require_content usr/local/share/x-chip/xorg/geany.conf 'tagbar_font=Luxi Sans 9'
require_content usr/local/share/x-chip/xorg/geany.conf 'msgwin_font=Luxi Mono 9'
require_content usr/local/share/x-chip/xorg/leafpadrc 'Luxi Mono 9'
require_content usr/local/share/x-chip/xorg/pcmanfm.conf 'view_mode=list'
require_content usr/local/share/x-chip/xorg/pcmanfm.conf 'show_statusbar=0'
require_content usr/local/share/x-chip/xorg/dillorc 'panel_size=small'
require_content usr/local/share/x-chip/xorg/dillorc 'show_save=NO'
require_content usr/local/share/x-chip/xorg/gtkrc-2.0 'gtk-font-name = "Luxi Sans 9"'
require_content usr/local/share/x-chip/xorg/gtkrc-2.0 'gtk-icon-theme-name = "x-chip"'
require_content usr/local/share/x-chip/xorg/gtkrc-2.0 'style "pocketclean"'
require_content usr/local/share/x-chip/xorg/gtk3-settings.ini 'gtk-font-name = Luxi Sans 9'
require_content usr/local/share/x-chip/xorg/gtk3-settings.ini 'gtk-icon-theme-name = x-chip'
require_content usr/local/share/x-chip/xorg/gtk3-settings.ini 'gtk-application-prefer-dark-theme = false'
require_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*transparent: false'
require_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*inheritPixmap: false'
require_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*fading: 0'
require_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*background: #0F1716'
require_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*cursorColor: #1F7A66'
require_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*font: 8x13'
require_content usr/local/bin/x-chip-close-app 'pkill -9'
require_content usr/local/bin/x-chip-close-app 'pcmanfm dillo geany leafpad gpicview ffplay mpg123'
require_content usr/local/bin/x-chip-close-game 'tic80 mgba-sdl1 mgba chocolate-doom pico8 goattracker sunvox sunvox-lofi pixilang'
require_content usr/local/bin/x-chip-close-game 'pkill -9 "$name"'
require_content usr/local/bin/x-chip-game-launch 'x-chip-tic80|x-chip-mgba|x-chip-doom|x-chip-pico8|x-chip-goattracker'
require_content usr/local/bin/x-chip-game-launch '/tmp/x-chip-game-launch.log'
require_content usr/local/bin/x-chip-game-launch 'pidof tic80'
require_content usr/local/bin/x-chip-mc 'TERM=rxvt-256color'
reject_content usr/local/bin/x-chip-mc 'COLORTERM'
require_content usr/local/bin/x-chip-mc 'MC_SKIN=${MC_SKIN:-pocketclean256}'
require_content usr/local/share/x-chip/xorg/mc.ini 'skin=pocketclean256'
require_content usr/local/share/x-chip/xorg/mc.ini '[Layout]'
require_content usr/local/share/x-chip/xorg/mc.ini 'command_prompt=0'
require_content usr/local/share/x-chip/xorg/mc.ini 'keybar_visible=0'
require_content usr/local/share/mc/skins/pocketclean256.ini 'description = Pocket Clean Skin'
require_content usr/local/share/mc/skins/pocketclean256.ini '256colors = true'
require_content usr/local/share/mc/skins/pocketclean256.ini 'main1 = rgb023'
require_content usr/local/share/mc/skins/pocketclean256.ini 'main2 = rgb455'
require_content usr/local/share/x-chip/xorg/jwmrc '#0F1716'
require_content usr/local/share/x-chip/xorg/jwmrc '#EAF2EF'
require_content usr/local/share/x-chip/xorg/jwmrc '#1F7A66'
require_content usr/local/share/x-chip/xorg/jwmrc '#223331'
require_content usr/local/share/x-chip/xorg/jwmrc 'x-chip-mc'
reject_content usr/local/share/x-chip/xorg/jwmrc ' -tr'
reject_content usr/local/share/x-chip/xorg/jwmrc 'transparent'
reject_content usr/local/share/x-chip/xorg/jwmrc '<Font>Sans-9</Font>'
reject_content usr/local/share/x-chip/xorg/geany.conf 'editor_font=Monospace 9'
reject_content usr/local/share/x-chip/xorg/geany.conf 'tagbar_font=Sans 9'
reject_content usr/local/share/x-chip/xorg/leafpadrc 'Monospace 10'
reject_content usr/local/share/x-chip/xorg/gtkrc-2.0 'gtk-font-name = "Sans 9"'
reject_content usr/local/share/x-chip/xorg/gtk3-settings.ini 'gtk-font-name = Sans 9'
reject_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*transparent: true'
reject_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*inheritPixmap: true'
reject_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*fading: 70'
reject_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*shading: 50'
reject_content usr/local/share/x-chip/xorg/Xdefaults 'Aterm*font: fixed'
reject_content usr/local/share/x-chip/xorg/jwmrc 'label="-">exec:x-chip-brightness down'
reject_content usr/local/share/x-chip/xorg/jwmrc 'label="+">exec:x-chip-brightness up'
reject_content usr/local/share/x-chip/xorg/jwmrc '<TrayButton label="Light"'
reject_content usr/local/share/x-chip/xorg/jwmrc '<TrayButton label="Close"'
reject_content usr/local/share/x-chip/xorg/jwmrc 'sudo reboot'
reject_content usr/local/share/x-chip/xorg/jwmrc 'sudo poweroff'
require_content usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example 'Driver "fbturbo"'
require_content usr/local/etc/ssh/sshd_config 'UseDNS no'
reject_content usr/local/etc/ssh/sshd_config 'UsePAM'
if [ "$SSH_PASSWORD_AUTH" = 1 ]; then
    require_content usr/local/etc/ssh/sshd_config 'PasswordAuthentication yes'
else
    require_content usr/local/etc/ssh/sshd_config 'PasswordAuthentication no'
fi
require_content usr/local/etc/ssh/sshd_config 'PermitEmptyPasswords no'
require_content usr/local/etc/ssh/sshd_config 'Subsystem sftp internal-sftp'
require_content etc/inittab 'ttyS0::respawn'
require_content etc/inittab 'x-chip-tty1-getty'
require_content tce/onboot.lst 'kmaps.tcz'
require_content tce/onboot.lst 'libasound.tcz'
require_content tce/onboot.lst 'alsa.tcz'
require_content tce/onboot.lst 'alsa-utils.tcz'
reject_content tce/onboot.lst 'Xorg.tcz'
reject_content tce/onboot.lst 'xf86-video-fbdev.tcz'
reject_content tce/onboot.lst 'xf86-video-fbturbo.tcz'
reject_content tce/onboot.lst 'flwm.tcz'
reject_content tce/onboot.lst 'jwm.tcz'
reject_content tce/onboot.lst 'aterm.tcz'
reject_content tce/onboot.lst 'ffmpeg.tcz'
reject_content tce/onboot.lst 'mpg123.tcz'
reject_content tce/onboot.lst 'sox.tcz'
reject_content tce/onboot.lst 'alsa-plugins.tcz'
require_content tce/media.lst 'ffmpeg.tcz'
require_content tce/media.lst 'mpg123.tcz'
require_content tce/xorg.lst 'Xorg.tcz'
require_content tce/xorg.lst 'xf86-video-fbdev.tcz'
reject_content tce/xorg.lst '^xf86-video-fbturbo.tcz'
require_content tce/xorg.lst 'flwm.tcz'
require_content tce/xorg.lst 'jwm.tcz'
require_content tce/xorg.lst 'aterm.tcz'
require_content tce/xorg.lst 'xrandr.tcz'
require_content tce/xorg.lst 'xinput.tcz'
require_content tce/xorg.lst 'dillo.tcz'
require_content tce/xorg.lst 'leafpad.tcz'
require_content tce/xorg.lst 'bc.tcz'
require_content tce/xorg.lst 'gpicview.tcz'
require_content tce/xorg.lst 'libffi6.tcz'
require_content tce/xorg.lst 'geany.tcz'
require_content tce/xorg.lst 'pcmanfm.tcz'
require_content tce/xorg.lst 'conky.tcz'

for script in \
    opt/x-chip-boot.sh \
    opt/x-chip-autologin.sh \
    opt/x-chip-tty1-getty.sh \
    opt/x-chip-early-debug.sh \
    usr/local/bin/x-chip-keyboard-status \
    usr/local/bin/x-chip-audio-status \
    usr/local/bin/x-chip-power-status \
    usr/local/bin/x-chip-term-hold \
    usr/local/bin/x-chip-mc \
    usr/local/bin/x-chip-status \
    usr/local/bin/x-chip-calc \
    usr/local/bin/x-chip-time \
    usr/local/bin/x-chip-open \
    usr/local/bin/x-chip-open-image \
    usr/local/bin/x-chip-open-pdf \
    usr/local/bin/x-chip-music \
    usr/local/bin/x-chip-video \
    usr/local/bin/x-chip-tic80 \
    usr/local/bin/x-chip-goattracker \
    usr/local/bin/x-chip-sunvox \
    usr/local/bin/x-chip-virtual-ans \
    usr/local/bin/x-chip-pixitracker \
    usr/local/bin/x-chip-pixitracker-1bit \
    usr/local/bin/x-chip-pixilang \
    usr/local/bin/x-chip-mgba \
    usr/local/bin/x-chip-pico8 \
    usr/local/bin/x-chip-games \
    usr/local/bin/x-chip-doom \
    usr/local/bin/x-chip-desktop-stats \
    usr/local/bin/x-chip-logs \
    usr/local/bin/x-chip-brightness \
    usr/local/bin/x-chip-wifi-menu \
    usr/local/bin/x-chip-media-on \
    usr/local/bin/x-chip-startx \
    usr/local/bin/x-chip-desktop-start \
    usr/local/bin/x-chip-gtk-cache \
    usr/local/bin/x-chip-close-app \
    usr/local/bin/x-chip-close-game \
    usr/local/bin/x-chip-game-launch \
    usr/local/bin/x-chip-x-apply-calibration \
    usr/local/bin/x-chip-x-keymap \
    usr/local/bin/x-chip-touch-calibrate \
    usr/local/bin/x-chip-xorg-launch-vt \
    usr/local/bin/x-chip-xorg-session \
    usr/local/bin/x-chip-load-rtl8812au \
    usr/local/sbin/x-chip-rtl8812au-hotplug \
    opt/bootlocal.sh; do
    require_shell_syntax "$script"
done

while IFS= read -r depfile; do
    reject_content "$depfile" 'KERNEL'
    while IFS= read -r dep; do
        dep=${dep%%#*}
        dep=${dep//[$'\t\r\n ']/}
        [ -n "$dep" ] || continue
        case "$dep" in
            *KERNEL*.tcz) continue ;;
            *.tcz) ;;
            *) dep="$dep.tcz" ;;
        esac
        require_entry "tce/optional/$dep"
    done <"$TMP_ROOT/$depfile"
done < <(grep -E '^(\./)?tce/optional/.*\.tcz\.dep$' "$TMP_LIST" | sed 's#^\./##')
require_pocketchip_keymap_complete

if [ "${PRESEED_TCZ:-1}" = 1 ]; then
    for ext_list in tce/onboot.lst tce/media.lst tce/xorg.lst; do
        [ -f "$ext_list" ] || continue
        while IFS= read -r ext; do
            ext=${ext%%#*}
            ext=${ext//[$'\t\r\n ']/}
            [ -n "$ext" ] || continue
            case "$ext" in
                *KERNEL*.tcz) continue ;;
                *.tcz) ;;
                *) ext="$ext.tcz" ;;
            esac
            require_entry "tce/optional/$ext"
        done < "$ext_list"
    done
    if has_entry "tce/optional/tic80.tcz"; then
        require_entry "tce/optional/tic80.tcz.dep"
        require_entry "tce/optional/mesa.tcz"
        require_entry "tce/optional/curl.tcz"
        require_entry "tce/optional/libasound.tcz"
        require_entry "tce/optional/gcc_libs.tcz"
        require_entry "tce/optional/Xlibs.tcz"
        require_content "tce/optional/tic80.tcz.dep" 'mesa.tcz'
        reject_content tce/onboot.lst 'tic80.tcz'
    fi
    if has_entry "tce/optional/goattracker.tcz"; then
        require_entry "tce/optional/goattracker.tcz.dep"
        require_entry "tce/optional/SDL.tcz"
        require_entry "tce/optional/gcc_libs.tcz"
        require_content "tce/optional/goattracker.tcz.dep" 'SDL.tcz'
        reject_content tce/onboot.lst 'goattracker.tcz'
    fi
    if has_entry "tce/optional/sunvox.tcz"; then
        require_entry "tce/optional/sunvox.tcz.dep"
        require_entry "tce/optional/sdl2.tcz"
        require_entry "tce/optional/libasound.tcz"
        require_entry "tce/optional/gcc_libs.tcz"
        require_entry "tce/optional/Xlibs.tcz"
        require_content "tce/optional/sunvox.tcz.dep" 'sdl2.tcz'
        require_content "tce/optional/sunvox.tcz.dep" 'libasound.tcz'
        reject_content tce/onboot.lst 'sunvox.tcz'
    fi
    require_warmplace_music_ext() {
        local ext=$1
        require_entry "tce/optional/$ext.tcz.dep"
        require_entry "tce/optional/sdl2.tcz"
        require_entry "tce/optional/libasound.tcz"
        require_entry "tce/optional/gcc_libs.tcz"
        require_entry "tce/optional/Xlibs.tcz"
        require_content "tce/optional/$ext.tcz.dep" 'sdl2.tcz'
        require_content "tce/optional/$ext.tcz.dep" 'libasound.tcz'
        require_content "tce/optional/$ext.tcz.dep" 'gcc_libs.tcz'
        require_content "tce/optional/$ext.tcz.dep" 'Xlibs.tcz'
        reject_content tce/onboot.lst "$ext.tcz"
    }
    for warmplace_ext in pixitracker pixitracker-1bit pixilang; do
        if has_entry "tce/optional/$warmplace_ext.tcz"; then
            require_warmplace_music_ext "$warmplace_ext"
        fi
    done
    if has_entry "tce/optional/mgba.tcz"; then
        require_entry "tce/optional/mgba.tcz.dep"
        require_entry "tce/optional/SDL.tcz"
        require_entry "tce/optional/pixman.tcz"
        require_entry "tce/optional/gcc_libs.tcz"
        require_content "tce/optional/mgba.tcz.dep" 'SDL.tcz'
        require_content "tce/optional/mgba.tcz.dep" 'pixman.tcz'
        reject_content tce/onboot.lst 'mgba.tcz'
    fi
    if has_entry "tce/optional/doom.tcz"; then
        require_entry "tce/optional/doom.tcz.dep"
        require_entry "tce/optional/sdl2.tcz"
        require_entry "tce/optional/sdl2_mixer.tcz"
        require_entry "tce/optional/sdl2_net.tcz"
        require_entry "tce/optional/libsamplerate.tcz"
        require_entry "tce/optional/gcc_libs.tcz"
        require_content "tce/optional/doom.tcz.dep" 'sdl2_mixer.tcz'
        require_content "tce/optional/doom.tcz.dep" 'libsamplerate.tcz'
        reject_content tce/onboot.lst 'doom.tcz'
    fi
fi

echo ">> verified $ROOTFS"
