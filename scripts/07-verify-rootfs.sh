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
trap 'rm -f "$TMP_LIST" "$TMP_VERBOSE"' EXIT
tar -tzf "$ROOTFS" >"$TMP_LIST"
tar -tvzf "$ROOTFS" >"$TMP_VERBOSE"

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
    tar -xOzf "$ROOTFS" "./$path" 2>/dev/null || tar -xOzf "$ROOTFS" "$path"
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
    extract_entry "$path" | grep -a "$pattern" >/dev/null || {
        echo "ERROR: /${path#/} does not contain expected marker: $pattern" >&2
        exit 1
    }
}

reject_content() {
    local path=$1 pattern=$2
    require_entry "$path"
    if extract_entry "$path" | grep -a "$pattern" >/dev/null; then
        echo "ERROR: /${path#/} contains unsupported marker: $pattern" >&2
        exit 1
    fi
}

require_shell_syntax() {
    local path=$1 tmp
    require_entry "$path"
    tmp=$(mktemp)
    extract_entry "$path" >"$tmp"
    if ! sh -n "$tmp"; then
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
        ""|"!"|"*")
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
        "!"|"*")
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
    etc/init.d/tc-config \
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
    opt/x-chip-firstboot.sh \
    opt/x-chip-autologin.sh \
    opt/x-chip-tty1-getty.sh \
    opt/x-chip-early-debug.sh \
    usr/local/bin/x-chip-keyboard-status \
    usr/local/bin/x-chip-audio-status \
    usr/local/bin/x-chip-power-status \
    usr/local/bin/x-chip-term-hold \
    usr/local/bin/x-chip-status \
    usr/local/bin/x-chip-calc \
    usr/local/bin/x-chip-time \
    usr/local/bin/x-chip-open-image \
    usr/local/bin/x-chip-music \
    usr/local/bin/x-chip-video \
    usr/local/bin/x-chip-desktop-stats \
    usr/local/bin/x-chip-logs \
    usr/local/bin/x-chip-brightness \
    usr/local/bin/x-chip-wifi-menu \
    usr/local/bin/x-chip-media-on \
    usr/local/bin/x-chip-startx \
    usr/local/bin/x-chip-desktop-start \
    usr/local/bin/x-chip-close-app \
    usr/local/bin/x-chip-x-apply-calibration \
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
    usr/local/share/icons/x-chip/16x16/apps/pcmanfm.xpm \
    usr/local/share/icons/x-chip/16x16/apps/geany.xpm \
    usr/local/share/icons/x-chip/16x16/places/folder.xpm \
    usr/local/share/icons/x-chip/16x16/places/user-home.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/text-x-generic.xpm \
    usr/local/share/x-chip/xorg/geany.conf \
    usr/local/share/x-chip/xorg/leafpadrc \
    usr/local/share/x-chip/xorg/pcmanfm.conf \
    usr/local/share/x-chip/xorg/dillorc \
    usr/local/share/x-chip/xorg/gtkrc-2.0 \
    usr/local/share/x-chip/xorg/gtk3-settings.ini \
    usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example \
    usr/local/etc/ssh/sshd_config \
    home/$SSH_USER/Pictures \
    home/$SSH_USER/Videos \
    home/$SSH_USER/Music \
    home/$SSH_USER/Downloads \
    usr/share/kmap/pocketchip.kmap \
    usr/share/kmap/pocketchip.loadkeys \
    lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo \
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
    opt/x-chip-firstboot.sh \
    opt/x-chip-autologin.sh \
    opt/x-chip-tty1-getty.sh \
    usr/local/bin/x-chip-keyboard-status \
    usr/local/bin/x-chip-audio-status \
    usr/local/bin/x-chip-power-status \
    usr/local/bin/x-chip-term-hold \
    usr/local/bin/x-chip-status \
    usr/local/bin/x-chip-calc \
    usr/local/bin/x-chip-time \
    usr/local/bin/x-chip-open-image \
    usr/local/bin/x-chip-music \
    usr/local/bin/x-chip-video \
    usr/local/bin/x-chip-desktop-stats \
    usr/local/bin/x-chip-logs \
    usr/local/bin/x-chip-brightness \
    usr/local/bin/x-chip-wifi-menu \
    usr/local/bin/x-chip-startx \
    usr/local/bin/x-chip-desktop-start \
    usr/local/bin/x-chip-close-app \
    usr/local/bin/x-chip-x-apply-calibration \
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
    usr/local/share/icons/x-chip/16x16/apps/pcmanfm.xpm \
    usr/local/share/icons/x-chip/16x16/apps/geany.xpm \
    usr/local/share/icons/x-chip/16x16/places/folder.xpm \
    usr/local/share/icons/x-chip/16x16/places/user-home.xpm \
    usr/local/share/icons/x-chip/16x16/mimetypes/text-x-generic.xpm \
    usr/local/share/x-chip/xorg/geany.conf \
    usr/local/share/x-chip/xorg/leafpadrc \
    usr/local/share/x-chip/xorg/pcmanfm.conf \
    usr/local/share/x-chip/xorg/dillorc \
    usr/local/share/x-chip/xorg/gtkrc-2.0 \
    usr/local/share/x-chip/xorg/gtk3-settings.ini \
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
require_mode_pattern usr/local/bin/x-chip-open-image '-rwx*'
require_mode_pattern usr/local/bin/x-chip-music '-rwx*'
require_mode_pattern usr/local/bin/x-chip-video '-rwx*'
require_mode_pattern usr/local/bin/x-chip-desktop-stats '-rwx*'
require_mode_pattern usr/local/bin/x-chip-logs '-rwx*'
require_mode_pattern usr/local/bin/x-chip-brightness '-rwx*'
require_mode_pattern usr/local/bin/x-chip-wifi-menu '-rwx*'
require_mode_pattern usr/local/bin/x-chip-startx '-rwx*'
require_mode_pattern usr/local/bin/x-chip-desktop-start '-rwx*'
require_mode_pattern usr/local/bin/x-chip-x-apply-calibration '-rwx*'
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
require_mode_pattern "home/$SSH_USER/.ssh" 'drwx------'
require_mode_pattern "home/$SSH_USER/.ssh/authorized_keys" '-rw-------'
if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 1 ]; then
    require_nonempty "home/$SSH_USER/.ssh/authorized_keys"
fi
if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    require_empty "home/$SSH_USER/.ssh/authorized_keys"
    require_empty "root/.ssh/authorized_keys"
    reject_entry etc/wpa_supplicant.conf
fi
if [ "$SSH_PASSWORD_AUTH" = 1 ]; then
    require_loginable_shadow
else
    reject_locked_shadow
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
require_content etc/os-release 'PRETTY_NAME="PocketCHIP TinyCore'
require_content etc/os-release 'VERSION_ID=16'
require_content etc/os-release "$PROJECT_REPO_URL"
require_content etc/issue 'PocketCHIP TinyCore'
require_content etc/motd 'PocketCHIP TinyCore'
require_content etc/init.d/tc-config 'udevadm settle --timeout=5'
require_content etc/init.d/tc-config 'fstab_pid:-'
require_content opt/x-chip-firstboot.sh 'ensure_devpts'
require_content opt/x-chip-firstboot.sh 'x-chip-firstboot.lock'
require_content opt/x-chip-firstboot.sh 'prepare_tce_runtime'
require_content opt/x-chip-firstboot.sh 'reset_tce_installed_markers'
require_content opt/x-chip-firstboot.sh 'materialized-tcz.lst'
require_content opt/x-chip-firstboot.sh '/usr/local/tce.installed'
require_content opt/x-chip-firstboot.sh 'load_tcz_boot_core'
require_content opt/x-chip-firstboot.sh 'load_tcz_onboot_background'
require_content opt/x-chip-firstboot.sh 'tce-load -il'
require_content opt/x-chip-firstboot.sh 'load_keymap'
require_content opt/x-chip-firstboot.sh 'configure_power_management'
require_content opt/x-chip-firstboot.sh 'load_audio_modules'
require_content opt/x-chip-firstboot.sh 'Power Amplifier DAC'
require_content opt/x-chip-firstboot.sh 'LCD_BRIGHTNESS_VALUE='
require_content opt/x-chip-firstboot.sh 'LCD brightness set to'
require_content opt/x-chip-firstboot.sh 'silence_kernel_console'
require_content opt/x-chip-firstboot.sh 'x-chip-console-ready'
require_order opt/x-chip-firstboot.sh '^silence_kernel_console$' '^touch /tmp/x-chip-console-ready'
require_order opt/x-chip-firstboot.sh '^reset_tce_installed_markers$' '^load_tcz_boot_core$'
require_order opt/x-chip-firstboot.sh '^touch /tmp/x-chip-console-ready' '^start_usb_debug_gadget$'
require_order opt/x-chip-firstboot.sh '^start_desktop$' '^load_tcz_onboot_background$'
require_content opt/x-chip-firstboot.sh 'start_usb_debug_gadget'
require_content opt/x-chip-firstboot.sh 'start_ssh'
require_content opt/x-chip-firstboot.sh 'start_wifi'
require_content opt/x-chip-firstboot.sh 'sync_time_background'
require_order opt/x-chip-firstboot.sh '^[[:space:]]*start_wifi$' '^[[:space:]]*sync_time_background$'
require_content opt/x-chip-firstboot.sh 'start_desktop'
require_content opt/x-chip-firstboot.sh 'x-chip-desktop-start --boot'
require_content opt/x-chip-firstboot.sh 'RTL8812AU boot autoload disabled'
require_content opt/x-chip-firstboot.sh 'load_rtl8812au_if_present'
require_content usr/local/sbin/x-chip-rtl8812au-hotplug 'modprobe 8812au'
require_content usr/local/sbin/x-chip-rtl8812au-hotplug 'remains the primary SSH/network adapter'
require_content etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules 'x-chip-rtl8812au-hotplug'
require_content etc/modprobe.d/8812au.conf 'options 8812au'
require_content opt/x-chip-tty1-getty.sh 'getty -n'
require_content opt/x-chip-tty1-getty.sh 'WAITED'
require_content opt/x-chip-autologin.sh 'login -f'
require_content usr/local/bin/x-chip-media-on 'ffplay'
require_content usr/local/bin/x-chip-media-on 'tce-load'
require_content usr/local/bin/x-chip-startx 'XORG_LIST=/tce/xorg.lst'
require_content usr/local/bin/x-chip-startx 'X_CHIP_WM'
require_content usr/local/bin/x-chip-startx 'openvt'
require_content usr/local/bin/x-chip-startx 'setsid'
require_content usr/local/bin/x-chip-startx 'chvt'
require_content usr/local/bin/x-chip-startx 'x-chip-xorg-launch-vt'
require_content usr/local/bin/x-chip-desktop-start 'X_CHIP_DESKTOP_AUTOSTART'
require_content usr/local/bin/x-chip-desktop-start 'x-chip-startx'
require_content usr/local/bin/x-chip-x-apply-calibration 'touchscreen-calibration.matrix'
require_content usr/local/bin/x-chip-x-apply-calibration 'libinput Calibration Matrix'
require_content usr/local/bin/x-chip-touch-calibrate 'xinput test-xi2'
require_content usr/local/bin/x-chip-touch-calibrate 'SAMPLES_PER_TARGET'
require_content usr/local/bin/x-chip-touch-calibrate 'Generated by x-chip-touch-calibrate'
require_content usr/local/bin/x-chip-xorg-session 'x-chip-x-apply-calibration'
require_content usr/local/bin/x-chip-xorg-session 'exec jwm'
require_content usr/local/bin/x-chip-xorg-launch-vt 'Xorg :0'
require_content usr/local/bin/x-chip-xorg-launch-vt 'vt$X_CHIP_VT'
require_content usr/local/bin/x-chip-xorg-launch-vt 'start_ssh_if_needed'
require_content usr/local/bin/x-chip-xorg-launch-vt 'x-chip-brightness apply'
require_content usr/local/bin/x-chip-brightness '/sys/class/backlight'
require_content usr/local/bin/x-chip-brightness 'MIN_BRIGHTNESS='
require_content usr/local/bin/x-chip-brightness 'filetool.sh -b'
require_content usr/local/bin/x-chip-power-status 'Battery:'
require_content usr/local/bin/x-chip-power-status 'USB: online='
require_content usr/local/bin/x-chip-term-hold 'Press enter to close.'
require_content usr/local/bin/x-chip-status 'Pocket Status'
require_content usr/local/bin/x-chip-status 'x-chip-status'
require_content usr/local/bin/x-chip-status 'ifconfig "$iface"'
require_content usr/local/bin/x-chip-calc 'bc -l'
require_content usr/local/bin/x-chip-time 'ntpd -nq'
require_content usr/local/bin/x-chip-time 'sync-background'
require_content usr/local/bin/x-chip-open-image 'gpicview'
require_content usr/local/bin/x-chip-music 'mpg123 -C'
require_content usr/local/bin/x-chip-video 'ffplay -autoexit'
require_content usr/local/bin/x-chip-desktop-stats 'conky -c'
require_content usr/local/bin/x-chip-wifi-menu 'iw dev "$iface" scan'
require_content usr/local/bin/x-chip-wifi-menu 'wpa_supplicant -B'
require_content usr/local/bin/x-chip-wifi-menu 'filetool.sh -b'
require_content usr/local/bin/x-chip-wifi-menu 'ifconfig "$iface"'
require_content usr/local/bin/x-chip-wifi-menu 'CLIENT_DRIVER=rtl8723bs'
require_content usr/local/bin/x-chip-wifi-menu 'SCAN_DRIVER=rtl8812au'
require_content usr/local/bin/x-chip-wifi-menu 'find_client_wifi_iface'
require_content usr/local/bin/x-chip-wifi-menu 'find_scan_wifi_iface'
require_content usr/local/bin/x-chip-wifi-menu 'scan-external'
require_content usr/local/bin/x-chip-wifi-menu 'sudo iw dev "$iface" scan'
require_content usr/local/bin/x-chip-logs '/var/log/x-chip-desktop.log'
require_content usr/local/etc/x-chip/display.conf 'LCD_BRIGHTNESS='
require_content usr/local/etc/x-chip/desktop.conf 'X_CHIP_DESKTOP_AUTOSTART=1'
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
require_content opt/.filetool.lst 'usr/local/share/x-chip/xorg/touchscreen-calibration.matrix'
require_content opt/.filetool.lst 'usr/local/etc/x-chip'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-logs'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-term-hold'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-status'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-calc'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-time'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-open-image'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-music'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-video'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-desktop-stats'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-brightness'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-wifi-menu'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-desktop-start'
require_content opt/.filetool.lst 'usr/local/bin/x-chip-close-app'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'Driver "fbdev"'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'AutoBindGPU'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'MatchProduct "1c25000.rtp"'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'CalibrationMatrix'
require_content etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'Driver "fbdev"'
require_content etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf 'CalibrationMatrix'
require_content usr/local/share/x-chip/xorg/touchscreen-calibration.matrix '-1.069801149 0.001502438'
require_content usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf '-1.069801149 0.001502438'
require_content usr/local/share/x-chip/xorg/jwmrc '<Tray'
require_content usr/local/share/x-chip/xorg/jwmrc '<IconPath>/usr/local/share/x-chip/xorg/icons</IconPath>'
require_content usr/local/share/x-chip/xorg/jwmrc '<DefaultIcon>pocket.xpm</DefaultIcon>'
require_content usr/local/share/x-chip/xorg/jwmrc '<StartupCommand>x-chip-x-apply-calibration</StartupCommand>'
require_content usr/local/share/x-chip/xorg/jwmrc '<RestartCommand>x-chip-x-apply-calibration</RestartCommand>'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Menu" icon="menu.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Browser" icon="browser.xpm">dillo -g 474x212+0+0'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Files" icon="files.xpm">pcmanfm'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Editor" icon="editor.xpm">leafpad'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Code" icon="code.xpm">geany -s -m -p -t'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Calculator" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Images" icon="image.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Music" icon="pocket.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Video" icon="monitor.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Apps" icon="apps.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Network" icon="network.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Brightness" icon="brightness.xpm"'
require_content usr/local/share/x-chip/xorg/jwmrc 'label="Window" icon="window.xpm"'
require_content usr/local/share/x-chip/xorg/icons/menu.xpm 'static char *menu_xpm'
require_content usr/local/share/x-chip/xorg/icons/terminal.xpm 'static char *terminal_xpm'
require_content usr/local/share/x-chip/xorg/icons/files.xpm 'static char *files_xpm'
require_content usr/local/share/icons/x-chip/index.theme 'Name=X-CHIP'
require_content usr/local/share/icons/x-chip/index.theme 'Directories=16x16/actions,16x16/apps'
require_content usr/local/share/icons/x-chip/16x16/places/folder.xpm 'static char *files_xpm'
require_content usr/local/share/icons/x-chip/16x16/actions/go-home.xpm 'static char *home_xpm'
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
require_content usr/local/share/x-chip/xorg/jwmrc '<Key mask="A" key="F4">close</Key>'
require_content usr/local/share/x-chip/xorg/jwmrc 'exec:dillo -g 474x212+0+0'
require_content usr/local/share/x-chip/xorg/jwmrc 'Apply Calibration'
require_content usr/local/share/x-chip/xorg/jwmrc '<Font>Sans-9</Font>'
require_content usr/local/share/x-chip/xorg/jwmrc 'Background type="image">/usr/local/share/x-chip/xorg/wallpapers/pocket-core.png'
require_content usr/local/share/x-chip/xorg/geany.conf 'pref_toolbar_show=false'
require_content usr/local/share/x-chip/xorg/geany.conf 'msgwindow_visible=false'
require_content usr/local/share/x-chip/xorg/geany.conf 'geometry=0;0;474;212;0;'
require_content usr/local/share/x-chip/xorg/leafpadrc 'Monospace 10'
require_content usr/local/share/x-chip/xorg/pcmanfm.conf 'view_mode=list'
require_content usr/local/share/x-chip/xorg/pcmanfm.conf 'show_statusbar=0'
require_content usr/local/share/x-chip/xorg/dillorc 'panel_size=small'
require_content usr/local/share/x-chip/xorg/dillorc 'show_save=NO'
require_content usr/local/share/x-chip/xorg/gtkrc-2.0 'gtk-font-name = "Sans 9"'
require_content usr/local/share/x-chip/xorg/gtkrc-2.0 'gtk-icon-theme-name = "x-chip"'
require_content usr/local/share/x-chip/xorg/gtk3-settings.ini 'gtk-font-name = Sans 9'
require_content usr/local/share/x-chip/xorg/gtk3-settings.ini 'gtk-icon-theme-name = x-chip'
require_content usr/local/bin/x-chip-close-app 'pkill -9'
require_content usr/local/bin/x-chip-close-app 'pcmanfm dillo geany leafpad gpicview ffplay mpg123'
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
    opt/x-chip-firstboot.sh \
    opt/x-chip-autologin.sh \
    opt/x-chip-tty1-getty.sh \
    opt/x-chip-early-debug.sh \
    usr/local/bin/x-chip-keyboard-status \
    usr/local/bin/x-chip-audio-status \
    usr/local/bin/x-chip-power-status \
    usr/local/bin/x-chip-term-hold \
    usr/local/bin/x-chip-status \
    usr/local/bin/x-chip-calc \
    usr/local/bin/x-chip-time \
    usr/local/bin/x-chip-open-image \
    usr/local/bin/x-chip-music \
    usr/local/bin/x-chip-video \
    usr/local/bin/x-chip-desktop-stats \
    usr/local/bin/x-chip-logs \
    usr/local/bin/x-chip-brightness \
    usr/local/bin/x-chip-wifi-menu \
    usr/local/bin/x-chip-media-on \
    usr/local/bin/x-chip-startx \
    usr/local/bin/x-chip-desktop-start \
    usr/local/bin/x-chip-x-apply-calibration \
    usr/local/bin/x-chip-touch-calibrate \
    usr/local/bin/x-chip-xorg-launch-vt \
    usr/local/bin/x-chip-xorg-session \
    usr/local/bin/x-chip-load-rtl8812au \
    usr/local/sbin/x-chip-rtl8812au-hotplug; do
    require_shell_syntax "$script"
done

while IFS= read -r depfile; do
    reject_content "$depfile" 'KERNEL'
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
fi

echo ">> verified $ROOTFS"
