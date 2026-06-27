#!/bin/bash -e

# Optional external RTL8812AU USB WiFi module, built against the just-built
# TinyCore CHIP kernel. The final rootfs assembler installs the resulting .ko
# only if its vermagic matches the kernel release.

HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
source ./config.env

resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$HERE/$1" ;;
    esac
}

[ "${RTL8812AU_BUILD:-1}" = 1 ] || {
    echo ">> RTL8812AU build disabled"
    exit 0
}

KDIR="$HERE/build/linux-${KERNEL_VERSION}"
[ -d "$KDIR" ] || { echo "run 'make kernel' first (missing $KDIR)" >&2; exit 1; }

SRC="$HERE/build/rtl8812au-src"
OUT_DIR="$HERE/build/rtl8812au"
PATCH_FILE=$(resolve_path "$RTL8812AU_PATCH")

command -v git >/dev/null || { echo "need git to fetch rtl8812au source" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    git clone "$RTL8812AU_REPO" "$SRC"
fi

git -C "$SRC" checkout -f "$RTL8812AU_COMMIT"
git -C "$SRC" clean -fdx

if [ -f "$PATCH_FILE" ]; then
    if git -C "$SRC" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
        git -C "$SRC" apply "$PATCH_FILE"
    else
        echo ">> skip rtl8812au patch (already applied or N/A): $(basename "$PATCH_FILE")"
    fi
fi

if ! grep -q 'X_CHIP_KBUILD_CFLAGS' "$SRC/Makefile"; then
    {
        echo
        echo "# X_CHIP_KBUILD_CFLAGS: Linux 6.18 Kbuild no longer reliably consumes EXTRA_CFLAGS from this vendor Makefile."
        echo "ccflags-y += \$(EXTRA_CFLAGS)"
        echo "ccflags-y += -I$SRC/include -I$SRC/platform -I$SRC/hal/phydm -I$SRC/hal/btc"
    } >> "$SRC/Makefile"
fi

if ! grep -q 'X_CHIP_TIMER_COMPAT' "$SRC/include/osdep_service_linux.h"; then
    sed -i '/#include <linux\/version.h>/a\
#include <linux/timer.h>\
#ifndef from_timer\
#define from_timer(var, callback_timer, timer_fieldname) timer_container_of(var, callback_timer, timer_fieldname)\
#endif\
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\
#ifndef del_timer_sync\
#define del_timer_sync(timer) timer_delete_sync(timer)\
#endif\
#endif\
/* X_CHIP_TIMER_COMPAT */' "$SRC/include/osdep_service_linux.h"
fi

CFG80211_C="$SRC/os_dep/linux/ioctl_cfg80211.c"
if ! grep -q 'X_CHIP_CFG80211_6_18' "$CFG80211_C"; then
    perl -0pi -e 's/static int cfg80211_rtw_set_wiphy_params\(struct wiphy \*wiphy, u32 changed\)/\/\* X_CHIP_CFG80211_6_18 *\/\nstatic int cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0))\n\tint radio_idx,\n#endif\n\tu32 changed)/' "$CFG80211_C"
    perl -0pi -e 's/(static int cfg80211_rtw_set_txpower\(struct wiphy \*wiphy,\n#if \(LINUX_VERSION_CODE >= KERNEL_VERSION\(3, 8, 0\)\)\n\tstruct wireless_dev \*wdev,\n#endif\n)/$1#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0))\n\tint radio_idx,\n#endif\n/' "$CFG80211_C"
    perl -0pi -e 's/(static int cfg80211_rtw_get_txpower\(struct wiphy \*wiphy,\n#if \(LINUX_VERSION_CODE >= KERNEL_VERSION\(3, 8, 0\)\)\n\tstruct wireless_dev \*wdev,\n#endif\n)/$1#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0))\n\tint radio_idx,\n#endif\n/' "$CFG80211_C"
fi

export ARCH CROSS_COMPILE
make -C "$SRC" -j1 \
    KVER="${KERNEL_VERSION}${KERNEL_LOCALVERSION}" \
    KSRC="$KDIR" \
    CONFIG_RTL8812A=y \
    CONFIG_RTL8821A=n \
    CONFIG_RTL8814A=n \
    CONFIG_PLATFORM_I386_PC=n \
    CONFIG_PLATFORM_ARM_SUNxI=n \
    CONFIG_PLATFORM_ARM_RPI=y

install -D -m644 "$SRC/8812au.ko" "$OUT_DIR/8812au.ko"
echo ">> built RTL8812AU module: $OUT_DIR/8812au.ko"
