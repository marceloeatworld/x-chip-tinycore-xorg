#!/bin/bash -e

# Headless finishing pass + pack the rootfs tar that x-chip-tools flashes:
#   - compile boot/boot.cmd -> /boot/boot.scr (u-boot loads zImage + dtb)
#   - point tce at the live CorePure repo + ship the onboot extension list
#   - start sshd from bootlocal
#   - pack build/rootfs -> $OUT

HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
source ./config.env
if [ "${PUBLIC_IMAGE:-0}" != 1 ] && [ -f "$SECRETS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS_ENV"
fi

if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    REQUIRE_WIFI_CONFIG=0
    REQUIRE_AUTHORIZED_KEYS=0
    SSH_PASSWORD_AUTH=1
    AUTHORIZED_KEYS_SOURCE=
    WIFI_SSID=
    WIFI_PSK=
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

if [ -z "${FAKEROOTKEY:-}" ]; then
    if [ "${ROOTFS_FORCE_FAKEROOT:-0}" = 1 ]; then
        if command -v fakeroot >/dev/null 2>&1; then
            exec fakeroot -- env ROOTFS_FORCE_FAKEROOT=0 "$0" "$@"
        fi
        echo "ERROR: ROOTFS_FORCE_FAKEROOT=1 but fakeroot is not installed" >&2
        exit 1
    fi
    if [ "$(id -u)" != 0 ]; then
        if command -v fakeroot >/dev/null 2>&1; then
            exec fakeroot -- "$0" "$@"
        fi
        echo "ERROR: rootfs assembly needs root or fakeroot to preserve ownership and device nodes" >&2
        echo "Use 'make container-build' or install fakeroot before running this script locally." >&2
        exit 1
    fi
fi

need_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [ "$1" = chown ]; then
        "$@" 2>/dev/null || true
    else
        "$@"
    fi
}
resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$HERE/$1" ;;
    esac
}

RFS="$HERE/build/rootfs"
MKIMAGE=${MKIMAGE:-mkimage}
if ! command -v "$MKIMAGE" >/dev/null 2>&1; then
    if [ -x "$HERE/result/bin/mkimage" ]; then
        MKIMAGE="$HERE/result/bin/mkimage"
    else
        echo "need u-boot-tools (mkimage)" >&2
        exit 1
    fi
fi

validate_rootfs_base() {
    local missing=0 required
    for required in bin/busybox sbin/init init etc/inittab etc/init.d/tc-config; do
        if [ ! -e "$RFS/$required" ]; then
            echo "ERROR: build/rootfs is not a complete CorePure rootfs; missing /$required" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ] || {
        echo "Run 'make base' again before assembling the rootfs." >&2
        exit 1
    }
}

validate_rootfs_base
[ -f "$RFS/boot/zImage" ] || { echo "run 'make kernel' first (no /boot/zImage)" >&2; exit 1; }

replace_colon_record() {
    local file=$1 mode=$2 key=$3 line=$4 tmp
    tmp=$(mktemp)
    if [ -f "$file" ]; then
        need_root awk -F: -v key="$key" '$1 != key' "$file" >"$tmp"
    fi
    printf '%s\n' "$line" >>"$tmp"
    need_root install -m "$mode" "$tmp" "$file"
    rm -f "$tmp"
}

install_text() {
    local mode=$1 dest=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    need_root install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
}

read_touch_calibration_matrix() {
    local source=$1 matrix fields
    [ -f "$source" ] || {
        echo "ERROR: missing touchscreen calibration source: $source" >&2
        exit 1
    }
    matrix=$(sed -n 's/#.*//; /^[[:space:]]*$/d; p; q' "$source")
    fields=$(printf '%s\n' "$matrix" | awk '{ print NF }')
    [ "$fields" = 9 ] || {
        echo "ERROR: touchscreen calibration matrix must contain 9 values: $source" >&2
        exit 1
    }
    printf '%s\n' "$matrix"
}

ssh_shadow_password() {
    local salt
    if [ "$SSH_PASSWORD_AUTH" != 1 ]; then
        printf ''
        return 0
    fi
    if [ -n "${SSH_PASSWORD_HASH:-}" ]; then
        case "$SSH_PASSWORD_HASH" in
            *:*) echo "ERROR: SSH_PASSWORD_HASH must not contain ':'" >&2; exit 1 ;;
        esac
        printf '%s' "$SSH_PASSWORD_HASH"
        return 0
    fi
    if [ -z "${SSH_PASSWORD:-}" ]; then
        echo "ERROR: SSH_PASSWORD must be non-empty when SSH_PASSWORD_AUTH=1" >&2
        exit 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: openssl is required to hash SSH_PASSWORD" >&2
        exit 1
    fi
    salt=${SSH_PASSWORD_SALT:-}
    if [ -z "$salt" ]; then
        salt=$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9./' | head -c 16)
        [ -n "$salt" ] || salt="xchip$(date +%s)"
    fi
    printf '%s\n' "$SSH_PASSWORD" | openssl passwd -6 -salt "$salt" -stdin
}

create_static_dev_nodes() {
    need_root install -d "$RFS/dev" "$RFS/dev/input" "$RFS/dev/net" "$RFS/dev/pts" "$RFS/dev/shm" "$RFS/dev/usb"

    make_node() {
        local path=$1 mode=$2 type=$3 major=$4 minor=$5
        if [ ! -c "$path" ]; then
            need_root rm -f "$path"
            if ! need_root mknod -m "$mode" "$path" "$type" "$major" "$minor"; then
                echo "WARN: could not create ${path#$RFS} static device node; relying on devtmpfs" >&2
            fi
        fi
    }

    make_node "$RFS/dev/console" 0600 c 5 1
    make_node "$RFS/dev/null" 0666 c 1 3
    make_node "$RFS/dev/zero" 0666 c 1 5
    make_node "$RFS/dev/full" 0666 c 1 7
    make_node "$RFS/dev/random" 0666 c 1 8
    make_node "$RFS/dev/urandom" 0666 c 1 9
    make_node "$RFS/dev/tty" 0666 c 5 0
    make_node "$RFS/dev/tty0" 0600 c 4 0
    make_node "$RFS/dev/tty1" 0600 c 4 1
    make_node "$RFS/dev/ttyS0" 0600 c 4 64
    make_node "$RFS/dev/net/tun" 0666 c 10 200
}

normalize_rootfs_metadata() {
    create_static_dev_nodes

    need_root chown -R 0:0 "$RFS"
    if [ -d "$RFS/home/$SSH_USER" ]; then
        need_root chown -R "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER"
    fi

    [ -e "$RFS/bin/busybox.suid" ] && {
        need_root chown 0:0 "$RFS/bin/busybox.suid"
        need_root chmod 4755 "$RFS/bin/busybox.suid"
    }
    [ -e "$RFS/usr/bin/sudo" ] && {
        need_root chown 0:0 "$RFS/usr/bin/sudo"
        need_root chmod 4755 "$RFS/usr/bin/sudo"
    }
    [ -e "$RFS/usr/local/lib/xorg/Xorg" ] && {
        need_root chown 0:0 "$RFS/usr/local/lib/xorg/Xorg"
        need_root chmod 4755 "$RFS/usr/local/lib/xorg/Xorg"
    }
    [ -e "$RFS/usr/local/lib/xorg/Xorg.wrap" ] && {
        need_root chown 0:0 "$RFS/usr/local/lib/xorg/Xorg.wrap"
        need_root chmod 4555 "$RFS/usr/local/lib/xorg/Xorg.wrap"
    }

    [ -e "$RFS/etc/shadow" ] && {
        need_root chown 0:0 "$RFS/etc/shadow"
        need_root chmod 600 "$RFS/etc/shadow"
    }
    [ -e "$RFS/etc/sudoers" ] && {
        need_root chown 0:0 "$RFS/etc/sudoers"
        need_root chmod 440 "$RFS/etc/sudoers"
    }
    [ -e "$RFS/etc/sudoers.d/$SSH_USER" ] && {
        need_root chown 0:0 "$RFS/etc/sudoers.d/$SSH_USER"
        need_root chmod 440 "$RFS/etc/sudoers.d/$SSH_USER"
    }

    if [ -d "$RFS/home/$SSH_USER/.ssh" ]; then
        need_root chown -R "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER/.ssh"
        need_root chmod 700 "$RFS/home/$SSH_USER/.ssh"
        [ -e "$RFS/home/$SSH_USER/.ssh/authorized_keys" ] && \
            need_root chmod 600 "$RFS/home/$SSH_USER/.ssh/authorized_keys"
    fi
    if [ -d "$RFS/root/.ssh" ]; then
        need_root chown -R 0:0 "$RFS/root/.ssh"
        need_root chmod 700 "$RFS/root/.ssh"
        [ -e "$RFS/root/.ssh/authorized_keys" ] && \
            need_root chmod 600 "$RFS/root/.ssh/authorized_keys"
    fi
}

install_early_debug() {
    install_text 0755 "$RFS/opt/x-chip-early-debug.sh" <<'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/opt/x-chip-early-debug.log
exec >>"$LOG" 2>&1
echo "=== x-chip-early-debug $(date 2>/dev/null || true) ==="

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts 2>/dev/null || true
if ! grep -q ' /dev/pts ' /proc/mounts 2>/dev/null; then
    mount -t devpts devpts /dev/pts -o mode=620,ptmxmode=666 2>/dev/null || \
        mount -t devpts devpts /dev/pts 2>/dev/null || true
fi

modprobe libcomposite 2>/dev/null || true
mkdir -p /sys/kernel/config 2>/dev/null || true
if ! grep -q ' /sys/kernel/config ' /proc/mounts 2>/dev/null; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

[ -d /sys/kernel/config/usb_gadget ] || {
    echo "WARN: usb gadget configfs not available"
    exit 0
}

G=/sys/kernel/config/usb_gadget/xchip_early
if [ -e "$G/UDC" ]; then
    current="$(cat "$G/UDC" 2>/dev/null || true)"
    [ -n "$current" ] && exit 0
fi

mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" 2>/dev/null || exit 0
echo 0x1d6b > "$G/idVendor" 2>/dev/null || true
echo 0x0104 > "$G/idProduct" 2>/dev/null || true
echo 0x0100 > "$G/bcdDevice" 2>/dev/null || true
echo 0x0200 > "$G/bcdUSB" 2>/dev/null || true
echo xchip-early > "$G/strings/0x409/serialnumber" 2>/dev/null || true
echo NTC > "$G/strings/0x409/manufacturer" 2>/dev/null || true
echo "CHIP TinyCore early debug" > "$G/strings/0x409/product" 2>/dev/null || true
echo "USB early debug network" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
echo 250 > "$G/configs/c.1/MaxPower" 2>/dev/null || true

FUNC=
if mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
    FUNC=rndis.usb0
elif mkdir -p "$G/functions/ecm.usb0" 2>/dev/null; then
    FUNC=ecm.usb0
else
    echo "WARN: no RNDIS/ECM gadget function available"
    exit 0
fi

echo de:ad:be:ef:54:01 > "$G/functions/$FUNC/dev_addr" 2>/dev/null || true
echo de:ad:be:ef:54:02 > "$G/functions/$FUNC/host_addr" 2>/dev/null || true
[ -e "$G/configs/c.1/$FUNC" ] || ln -s "$G/functions/$FUNC" "$G/configs/c.1/$FUNC" 2>/dev/null || true

UDC="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
[ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null || true

i=0
while [ "$i" -lt 10 ]; do
    [ -e /sys/class/net/usb0 ] && break
    i=$((i + 1))
    sleep 1
done

if [ -e /sys/class/net/usb0 ]; then
    ifconfig usb0 192.168.82.1 netmask 255.255.255.0 up 2>/dev/null || true
    echo "USB early debug network ready on 192.168.82.1"
else
    echo "WARN: usb0 did not appear"
fi
EOF

    if [ -f "$RFS/etc/init.d/rcS" ] && ! grep -q 'x-chip early debug' "$RFS/etc/init.d/rcS"; then
        local tmp
        tmp=$(mktemp)
        awk '
            { print }
            $0 == "/bin/mount -a" {
                print ""
                print "# --- x-chip early debug ---"
                print "/opt/x-chip-early-debug.sh &"
            }
        ' "$RFS/etc/init.d/rcS" >"$tmp"
        need_root install -m755 "$tmp" "$RFS/etc/init.d/rcS"
        rm -f "$tmp"
    fi
}

install_runtime_identity() {
    local shadow_password
    need_root install -d "$RFS/etc" "$RFS/etc/sysconfig" "$RFS/home" "$RFS/opt"
    [ -f "$RFS/etc/passwd" ] || echo 'root:x:0:0:root:/root:/bin/sh' | need_root tee "$RFS/etc/passwd" >/dev/null
    [ -f "$RFS/etc/group" ] || echo 'root:x:0:' | need_root tee "$RFS/etc/group" >/dev/null
    [ -f "$RFS/etc/shadow" ] || echo 'root:*:19000:0:99999:7:::' | need_root tee "$RFS/etc/shadow" >/dev/null

    replace_colon_record "$RFS/etc/group" 0644 "$SSH_USER" \
        "$SSH_USER:x:$SSH_GID:"
    for group in \
        staff:50 \
        adm:4 \
        dialout:20 \
        audio:29 \
        video:44 \
        plugdev:46 \
        users:100 \
        netdev:101 \
        input:102 \
        render:103 \
        bluetooth:104 \
        gpio:105 \
        i2c:106 \
        spi:107; do
        replace_colon_record "$RFS/etc/group" 0644 "${group%%:*}" \
            "${group%%:*}:x:${group##*:}:$SSH_USER"
    done
    replace_colon_record "$RFS/etc/passwd" 0644 "$SSH_USER" \
        "$SSH_USER:x:$SSH_UID:$SSH_GID:CHIP User:/home/$SSH_USER:/bin/sh"
    shadow_password=$(ssh_shadow_password)
    replace_colon_record "$RFS/etc/shadow" 0600 "$SSH_USER" \
        "$SSH_USER:$shadow_password:19000:0:99999:7:::"

    echo "$CHIP_HOSTNAME" | need_root tee "$RFS/etc/hostname" >/dev/null
    echo "$SSH_USER" | need_root tee "$RFS/etc/sysconfig/tcuser" >/dev/null
    install_text 0644 "$RFS/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$CHIP_HOSTNAME

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

    need_root install -d -m700 "$RFS/home/$SSH_USER/.ssh" "$RFS/root/.ssh"
    local keys_src=
    if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 1 ]; then
        if [ -f "$AUTHORIZED_KEYS_SOURCE" ]; then
            keys_src=$AUTHORIZED_KEYS_SOURCE
        elif [ -f "$HOME/.ssh/pocket.pub" ]; then
            keys_src=$HOME/.ssh/pocket.pub
        elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
            keys_src=$HOME/.ssh/id_ed25519.pub
        fi
    fi

    if [ -n "$keys_src" ]; then
        need_root install -m600 "$keys_src" "$RFS/home/$SSH_USER/.ssh/authorized_keys"
        need_root install -m600 "$keys_src" "$RFS/root/.ssh/authorized_keys"
    else
        if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 1 ]; then
            echo "ERROR: no authorized_keys source found" >&2
            echo "Set AUTHORIZED_KEYS_SOURCE or create ~/.ssh/pocket.pub before building." >&2
            exit 1
        fi
        echo "WARN: no authorized_keys source found; SSH login will need manual setup" >&2
        need_root install -m600 /dev/null "$RFS/home/$SSH_USER/.ssh/authorized_keys"
        need_root install -m600 /dev/null "$RFS/root/.ssh/authorized_keys"
    fi
    need_root chown -R "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER"
    need_root chmod 700 "$RFS/root/.ssh"

    need_root install -d "$RFS/etc/sudoers.d"
    install_text 0440 "$RFS/etc/sudoers.d/$SSH_USER" <<EOF
$SSH_USER ALL=(ALL) NOPASSWD: ALL
EOF
    need_root touch "$RFS/etc/sudoers"
    need_root grep -Eq "^$SSH_USER[[:space:]]+ALL=\\(ALL\\)[[:space:]]+NOPASSWD:[[:space:]]*ALL" "$RFS/etc/sudoers" 2>/dev/null || \
        echo "$SSH_USER ALL=(ALL) NOPASSWD: ALL" | need_root tee -a "$RFS/etc/sudoers" >/dev/null
}

install_os_branding() {
    local version_id
    version_id=${TINYCORE_VERSION%%.*}
    install_text 0644 "$RFS/etc/os-release" <<EOF
NAME="PocketCHIP TinyCore"
VERSION="$TINYCORE_VERSION"
ID=pocketchip-tinycore
ID_LIKE=tinycore
VERSION_ID=$version_id
PRETTY_NAME="PocketCHIP TinyCore $TINYCORE_VERSION"
ANSI_COLOR="0;34"
HOME_URL="$PROJECT_REPO_URL"
BUG_REPORT_URL="$PROJECT_REPO_URL/issues"
EOF

    install_text 0644 "$RFS/etc/issue" <<EOF
PocketCHIP TinyCore $TINYCORE_VERSION \n \l

EOF

    install_text 0644 "$RFS/etc/motd" <<EOF
PocketCHIP TinyCore $TINYCORE_VERSION
EOF
}

install_runtime_mounts() {
    need_root install -d -m1777 "$RFS/tmp"
    need_root install -d -m0755 "$RFS/run" "$RFS/var/run" "$RFS/etc/udev/rules.d"
    need_root install -d -m0775 "$RFS/var/lock"

    install_text 0644 "$RFS/etc/fstab" <<'EOF'
# /etc/fstab
proc            /proc        proc    defaults          0       0
sysfs           /sys         sysfs   defaults          0       0
devpts          /dev/pts     devpts  defaults          0       0
tmpfs           /dev/shm     tmpfs   defaults          0       0
tmpfs           /tmp         tmpfs   mode=1777,nosuid,nodev 0 0
tmpfs           /run         tmpfs   mode=0755,nosuid,nodev 0 0
tmpfs           /var/run     tmpfs   mode=0755,nosuid,nodev 0 0
tmpfs           /var/lock    tmpfs   mode=0775,nosuid,nodev 0 0
EOF

    if [ -f "$RFS/tmp/98-tc.rules" ]; then
        need_root install -m0644 "$RFS/tmp/98-tc.rules" "$RFS/etc/udev/rules.d/98-tc.rules"
    else
        install_text 0644 "$RFS/etc/udev/rules.d/98-tc.rules" <<'EOF'
KERNEL=="ram*", SUBSYSTEM=="block", GOTO="tc.rules_end"
KERNEL=="loop*", SUBSYSTEM=="block", GOTO="tc.rules_end"
ACTION=="add",		SUBSYSTEM=="block",	RUN+="/bin/sh -c '/usr/sbin/rebuildfstab'"
ACTION=="remove",	SUBSYSTEM=="block",	RUN+="/bin/sh -c '/usr/sbin/rebuildfstab'"
LABEL="tc.rules_end"
EOF
    fi
}

install_console_config() {
    install_text 0755 "$RFS/opt/x-chip-autologin.sh" <<'EOF'
#!/bin/sh
exec /bin/login -f @SSH_USER@
EOF
    need_root sed -i "s/@SSH_USER@/$SSH_USER/g" "$RFS/opt/x-chip-autologin.sh"

    install_text 0755 "$RFS/opt/x-chip-tty1-getty.sh" <<'EOF'
#!/bin/sh
READY=/dev/shm/x-chip/console-ready
WAITED=0
while [ ! -e "$READY" ] && [ "$WAITED" -lt 30 ]; do
	sleep 1
	WAITED=$((WAITED + 1))
done

exec </dev/tty1 >/dev/tty1 2>&1
stty sane echo icanon isig icrnl opost onlcr 2>/dev/null || true

if [ -w /dev/tty1 ]; then
	printf '\033c\033[2J\033[H' 2>/dev/null || true
	printf 'PocketCHIP TinyCore ready - kernel %s\n\n' "$(uname -r)" 2>/dev/null || true
	if [ ! -e "$READY" ]; then
		printf 'Boot runtime is still running; see /opt/x-chip-boot.log\n\n' 2>/dev/null || true
	fi
fi

exec /sbin/getty -n -l /opt/x-chip-autologin.sh 38400 tty1
EOF
    replace_colon_record "$RFS/etc/inittab" 0644 tty1 \
        'tty1::respawn:/opt/x-chip-tty1-getty.sh'
    replace_colon_record "$RFS/etc/inittab" 0644 ttyS0 \
        'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100'
}

patch_tinycore_tce_setup() {
    local file="$RFS/usr/bin/tce-setup" tmp
    [ -f "$file" ] || return 0
    if grep -q 'MOUNTPOINT="/tmp"; TCE_DIR="tce"' "$file"; then
        tmp=$(mktemp)
        sed 's/MOUNTPOINT="\/tmp"; TCE_DIR="tce"/MOUNTPOINT=""; TCE_DIR="tce"/' "$file" >"$tmp"
        need_root install -m755 "$tmp" "$file"
        rm -f "$tmp"
    fi
}

patch_tinycore_tc_config() {
    local file="$RFS/etc/init.d/tc-config" tmp
    [ -f "$file" ] || return 0

    tmp=$(mktemp)
    awk '{
        if ($0 == "/sbin/udevadm settle") {
            print "/sbin/udevadm settle --timeout=5 >/dev/null 2>&1 || true"
        } else if ($0 ~ /^[[:space:]]*wait \$fstab_pid[[:space:]]*$/) {
            print "[ -n \"${fstab_pid:-}\" ] && wait \"$fstab_pid\" || true"
        } else {
            print
        }
    }' "$file" >"$tmp"
    need_root install -m755 "$tmp" "$file"
    rm -f "$tmp"
}

write_wifi_config() {
    if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
        need_root rm -f "$RFS/etc/wpa_supplicant.conf"
        return 0
    fi
    if [ -z "${WIFI_SSID:-}" ]; then
        if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
            echo "ERROR: WIFI_SSID is not set" >&2
            echo "Copy secrets.env.example to secrets.env and set WIFI_SSID/WIFI_PSK, or build with REQUIRE_WIFI_CONFIG=0." >&2
            exit 1
        fi
        return 0
    fi
    if [ -z "${WIFI_PSK:-}" ]; then
        if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
            echo "ERROR: WIFI_SSID is set but WIFI_PSK is missing" >&2
            echo "Set WIFI_PSK in secrets.env, or build with REQUIRE_WIFI_CONFIG=0." >&2
            exit 1
        fi
        echo "WARN: WIFI_SSID set but WIFI_PSK missing; WiFi config not written" >&2
        return 0
    fi

    local ssid_quoted psk_quoted
    ssid_quoted=$(printf '%s' "$WIFI_SSID" | sed 's/\\/\\\\/g; s/"/\\"/g')
    psk_quoted=$(printf '%s' "$WIFI_PSK" | sed 's/\\/\\\\/g; s/"/\\"/g')
    need_root install -d "$RFS/etc"
    install_text 0600 "$RFS/etc/wpa_supplicant.conf" <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=0
country=$WIFI_COUNTRY

network={
	ssid="$ssid_quoted"
	psk="$psk_quoted"
	key_mgmt=WPA-PSK
}
EOF
}

install_board_runtime_config() {
    need_root install -d "$RFS/etc/modprobe.d"
    install_text 0644 "$RFS/etc/modprobe.d/r8723bs.conf" <<'EOF'
options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0
EOF
    need_root touch "$RFS/etc/modprobe.conf"
    need_root grep -qxF 'options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0' "$RFS/etc/modprobe.conf" 2>/dev/null || \
        echo 'options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0' | need_root tee -a "$RFS/etc/modprobe.conf" >/dev/null
}

validate_pocketchip_bkeymap() {
    local map=$1 normal_prefix special_prefix
    normal_prefix=$(od -An -tx1 -j264 -N16 "$map" | tr -d ' \n')
    [ "$normal_prefix" = "021b0031003200330034003500360037" ] || {
        echo "ERROR: generated PocketCHIP keymap is missing the normal US key entries" >&2
        return 1
    }
    special_prefix=$(od -An -tx1 -j816 -N10 "$map" | tr -d ' \n')
    [ "$special_prefix" = "0b7b007d005b005d007c" ] || {
        echo "ERROR: generated PocketCHIP keymap is missing Fn/AltGr special entries" >&2
        return 1
    }
}

install_keymap() {
    local keymap_src keymap_base keymap_bin keymap_err
    keymap_src=$(resolve_path "$KEYMAP_SOURCE")
    [ -f "$keymap_src" ] || {
        echo "ERROR: keymap source not found: $keymap_src" >&2
        return 1
    }
    keymap_base="$HERE/build/linux-$KERNEL_VERSION/drivers/tty/vt/defkeymap.map"
    [ -f "$keymap_base" ] || {
        echo "ERROR: base console keymap not found: $keymap_base" >&2
        return 1
    }
    command -v loadkeys >/dev/null || {
        echo "ERROR: loadkeys missing on build host; cannot build complete PocketCHIP keymap" >&2
        return 1
    }

    keymap_bin=$(mktemp)
    keymap_err=$(mktemp)
    # pocketchip.kmap is a loadkeys overlay, not a complete map. Always merge it
    # with the kernel's default Linux console map before converting to BusyBox
    # loadkmap format; compiling the overlay alone breaks normal keys.
    if ! loadkeys -q -b "$keymap_base" "$keymap_src" >"$keymap_bin" 2>"$keymap_err"; then
        echo "ERROR: PocketCHIP keymap conversion failed" >&2
        sed 's/^/ERROR: loadkeys: /' "$keymap_err" >&2 || true
        rm -f "$keymap_bin" "$keymap_err"
        return 1
    fi
    validate_pocketchip_bkeymap "$keymap_bin" || {
        rm -f "$keymap_bin" "$keymap_err"
        return 1
    }
    need_root install -d "$RFS/usr/share/kmap"
    need_root install -m644 "$keymap_src" "$RFS/usr/share/kmap/pocketchip.loadkeys"
    need_root install -m644 "$keymap_bin" "$RFS/usr/share/kmap/pocketchip.kmap"
    rm -f "$keymap_bin" "$keymap_err"
}

install_keyboard_debug_tools() {
    need_root install -d "$RFS/usr/local/bin"
    install_text 0755 "$RFS/usr/local/bin/x-chip-keyboard-status" <<'EOF'
#!/bin/sh
echo "== modules =="
lsmod | grep -E '(^tca8418_keypad|^matrix_keymap|^sun4i_ts)' || true

echo
echo "== input devices =="
cat /proc/bus/input/devices 2>/dev/null | awk '
	/^I: / { block=$0 "\n"; keep=0; next }
	/^$/ {
		if (keep) print block
		block=""
		keep=0
		next
	}
	{
		block=block $0 "\n"
		if ($0 ~ /Name=.*tca8418/ || $0 ~ /Name=.*1c25000.rtp/) keep=1
	}
	END { if (keep) print block }
'

echo
echo "== keymap =="
ls -l /usr/share/kmap/pocketchip.* 2>/dev/null || true
if [ -r /var/log/loadkmap.log ]; then
	echo
	echo "== loadkmap log =="
	cat /var/log/loadkmap.log
fi

echo
echo "== tty console =="
cat /proc/consoles 2>/dev/null || true
cat /proc/sys/kernel/printk 2>/dev/null || true
EOF
}

install_hardware_debug_tools() {
    need_root install -d "$RFS/usr/local/bin"
    need_root install -d "$RFS/usr/local/etc/x-chip"
    need_root install -d "$RFS/usr/local/share/x-chip"
    install_text 0644 "$RFS/usr/local/etc/x-chip/display.conf" <<EOF
LCD_BRIGHTNESS=${LCD_BRIGHTNESS:-6}
EOF
    install_text 0644 "$RFS/usr/local/etc/x-chip/desktop.conf" <<EOF
X_CHIP_DESKTOP_AUTOSTART=${X_CHIP_DESKTOP_AUTOSTART:-1}
X_CHIP_DESKTOP_WM=${X_CHIP_DESKTOP_WM:-jwm}
X_CHIP_DESKTOP_VT=${X_CHIP_DESKTOP_VT:-2}
EOF
    install_text 0644 "$RFS/usr/local/etc/x-chip/desktop-stats.conf" <<EOF
X_CHIP_DESKTOP_STATS=${X_CHIP_DESKTOP_STATS:-0}
EOF
    install_text 0644 "$RFS/usr/local/etc/x-chip/wifi.conf" <<'EOF'
X_CHIP_WIFI_CLIENT_DRIVER=rtl8723bs
X_CHIP_WIFI_SCAN_DRIVER=rtl8812au
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-audio-status" <<'EOF'
#!/bin/sh
echo "== ALSA cards =="
cat /proc/asound/cards 2>/dev/null || true

echo
echo "== ALSA devices =="
cat /proc/asound/devices 2>/dev/null || true

echo
echo "== modules =="
lsmod | grep -E '(^snd|sun4i|simple_card)' || true

echo
echo "== aplay =="
command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null || true

echo
echo "== mixer =="
command -v amixer >/dev/null 2>&1 && amixer scontrols 2>/dev/null || true
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-power-status" <<'EOF'
#!/bin/sh

read_one() {
	[ -r "$1" ] && sed -n '1p' "$1" 2>/dev/null
}

fmt_uv() {
	v=$1
	case "$v" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s.%03d V' "$((v / 1000000))" "$(((v % 1000000) / 1000))"
}

fmt_ua() {
	v=$1
	case "$v" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s mA' "$((v / 1000))"
}

echo "Power"
echo "====="

bat=
for p in /sys/class/power_supply/*; do
	[ -e "$p" ] || continue
	[ "$(read_one "$p/type")" = Battery ] && { bat=$p; break; }
done
if [ -n "$bat" ]; then
	cap=$(read_one "$bat/capacity")
	status=$(read_one "$bat/status")
	voltage=$(read_one "$bat/voltage_now")
	current=$(read_one "$bat/current_now")
	printf 'Battery: %s%% %s\n' "${cap:-?}" "${status:-unknown}"
	[ -n "$voltage" ] && printf 'Voltage: ' && fmt_uv "$voltage" && printf '\n'
	[ -n "$current" ] && printf 'Current: ' && fmt_ua "$current" && printf '\n'
else
	echo "Battery: not found"
fi

for name in axp20x-usb axp20x-ac; do
	p=/sys/class/power_supply/$name
	[ -d "$p" ] || continue
	online=$(read_one "$p/online")
	voltage=$(read_one "$p/voltage_now")
	current=$(read_one "$p/current_now")
	label=$name
	[ "$name" = axp20x-usb ] && label=USB
	[ "$name" = axp20x-ac ] && label=AC
	printf '%s: online=%s' "$label" "${online:-?}"
	[ -n "$voltage" ] && printf ' ' && fmt_uv "$voltage"
	[ -n "$current" ] && printf ' ' && fmt_ua "$current"
	printf '\n'
done

for c in /sys/devices/system/cpu/cpu*/cpufreq; do
	[ -d "$c" ] || continue
	gov=$(read_one "$c/scaling_governor")
	freq=$(read_one "$c/scaling_cur_freq")
	[ -n "$freq" ] && printf 'CPU: %s MHz %s\n' "$((freq / 1000))" "${gov:-}"
	break
done

for z in /sys/class/thermal/thermal_zone*; do
	[ -r "$z/temp" ] || continue
	temp=$(read_one "$z/temp")
	printf 'Temp: %s.%s C\n' "$((temp / 1000))" "$(((temp % 1000) / 100))"
	break
done
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-term-hold" <<'EOF'
#!/bin/sh

if [ "$#" -eq 0 ]; then
	echo "Usage: x-chip-term-hold COMMAND [ARG...]"
	echo
	echo "Press enter to close."
	read _ || true
	exit 2
fi

"$@"
status=$?

echo
if [ "$status" -ne 0 ]; then
	echo "Command exited with status $status"
fi
echo "Press enter to close."
read _ || true
exit 0
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-mc" <<'EOF'
#!/bin/sh

case "${TERM:-}" in
	*256color) ;;
	*)
		TERM=rxvt-256color
		export TERM
		;;
esac

MC_SKIN=${MC_SKIN:-pocketclean256}
export MC_SKIN

ensure_x_chip_mc_ext() {
	conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/mc
	ext="$conf_dir/mc.ext.ini"
	snippet=/usr/local/share/x-chip/xorg/mc-media.ext.ini
	[ -r "$snippet" ] || return 0
	mkdir -p "$conf_dir"
	if [ ! -f "$ext" ]; then
		if [ -r /usr/local/etc/mc/mc.ext.ini ]; then
			cp /usr/local/etc/mc/mc.ext.ini "$ext"
		else
			printf '[mc.ext.ini]\nVersion=4.0\n\n' > "$ext"
		fi
	fi
	grep -q 'x-chip media handlers' "$ext" 2>/dev/null && return 0
	tmp="$ext.tmp.$$"
	awk -v snippet="$snippet" '
		BEGIN { inserted = 0 }
		!inserted && /^\[[^]]+\]/ && $0 != "[mc.ext.ini]" {
			while ((getline line < snippet) > 0) print line
			close(snippet)
			print ""
			inserted = 1
		}
		{ print }
		END {
			if (!inserted) {
				while ((getline line < snippet) > 0) print line
				close(snippet)
			}
		}
	' "$ext" > "$tmp" && mv "$tmp" "$ext"
}

ensure_x_chip_mc_ext
exec mc "$@"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-status" <<'EOF'
#!/bin/sh

first_wifi_iface() {
	for iface_path in /sys/class/net/wlan* /sys/class/net/wlp*; do
		[ -e "$iface_path" ] || continue
		printf '%s\n' "${iface_path##*/}"
		return 0
	done
	return 1
}

read_one() {
	[ -r "$1" ] && sed -n '1p' "$1" 2>/dev/null
}

show_power() {
	bat=
	for p in /sys/class/power_supply/*; do
		[ -e "$p" ] || continue
		type=$(read_one "$p/type")
		[ "$type" = Battery ] && { bat=$p; break; }
	done
	if [ -n "$bat" ]; then
		cap=$(read_one "$bat/capacity")
		status=$(read_one "$bat/status")
		printf 'Battery: %s%% %s\n' "${cap:-?}" "${status:-unknown}"
	else
		echo "Battery: not found"
	fi
	usb=?
	ac=?
	[ -r /sys/class/power_supply/axp20x-usb/online ] && usb=$(read_one /sys/class/power_supply/axp20x-usb/online)
	[ -r /sys/class/power_supply/axp20x-ac/online ] && ac=$(read_one /sys/class/power_supply/axp20x-ac/online)
	printf 'Power: USB=%s AC=%s\n' "$usb" "$ac"
}

show_wifi() {
	iface=$(first_wifi_iface 2>/dev/null || true)
	if [ -z "$iface" ]; then
		echo "WiFi: no interface"
		return
	fi
	ip4=
	if command -v ip >/dev/null 2>&1; then
		ip4=$(ip addr show "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet \([^ ]*\).*/\1/p' | head -n 1)
	elif command -v ifconfig >/dev/null 2>&1; then
		ip4=$(ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet addr:\([^ ]*\).*/\1/p; s/.*inet \([0-9.][0-9.]*\).*/\1/p' | head -n 1)
	fi
	link=$(iw dev "$iface" link 2>/dev/null)
	ssid=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1)
	signal=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*signal: //p' | head -n 1)
	[ -n "$ssid" ] || ssid=disconnected
	printf 'WiFi: %s %s\n' "$iface" "$ssid"
	[ -n "$ip4" ] && printf 'IP: %s\n' "$ip4"
	[ -n "$signal" ] && printf 'Signal: %s\n' "$signal"
}

show_display() {
	bl=
	for p in /sys/class/backlight/*; do
		[ -d "$p" ] || continue
		bl=$p
		break
	done
	if [ -n "$bl" ]; then
		cur=$(read_one "$bl/brightness")
		max=$(read_one "$bl/max_brightness")
		printf 'Brightness: %s/%s\n' "${cur:-?}" "${max:-?}"
	fi
}

show_cpu() {
	temp=
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/temp" ] || continue
		temp=$(read_one "$z/temp")
		break
	done
	freq=
	for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
		[ -r "$c" ] || continue
		freq=$(read_one "$c")
		break
	done
	[ -n "$temp" ] && printf 'Temp: %s.%s C\n' "$((temp / 1000))" "$(((temp % 1000) / 100))"
	[ -n "$freq" ] && printf 'CPU: %s MHz\n' "$((freq / 1000))"
	[ -r /proc/loadavg ] && printf 'Load: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
}

show_memory_disk() {
	awk '
		$1 == "MemTotal:" { total = int($2 / 1024) }
		$1 == "MemAvailable:" { avail = int($2 / 1024) }
		END {
			if (total > 0) printf "RAM: %d/%d MB free\n", avail, total
		}
	' /proc/meminfo 2>/dev/null
	df -h / 2>/dev/null | awk 'NR == 2 { printf "Disk /: %s/%s used %s\n", $3, $2, $5 }'
}

draw() {
	clear 2>/dev/null || true
	echo "Pocket Status"
	echo "============="
	show_power
	show_wifi
	show_display
	show_cpu
	show_memory_disk
}

if [ "${1:-}" = once ]; then
	draw
	exit 0
fi

while :; do
	draw
	echo
	printf '[r] refresh  [q] close > '
	read choice || exit 0
	case "$choice" in
		q|Q) exit 0 ;;
	esac
done
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-calc" <<'EOF'
#!/bin/sh

need_bc() {
	command -v bc >/dev/null 2>&1 || {
		echo "Calculator unavailable: bc is not installed." >&2
		exit 1
	}
}

need_bc

if [ "$#" -gt 0 ]; then
	printf '%s\n' "$*" | bc -l
	exit $?
fi

clear 2>/dev/null || true
echo "Calculator"
echo "=========="
echo "Type an expression, or q to close."
echo

while :; do
	printf 'calc> '
	read expr || exit 0
	case "$expr" in
		q|Q|quit|exit) exit 0 ;;
		'') continue ;;
	esac
	printf '%s\n' "$expr" | bc -l
done
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-time" <<'EOF'
#!/bin/sh

set -u

SERVERS=${X_CHIP_NTP_SERVERS:-"0.pool.ntp.org 1.pool.ntp.org time.cloudflare.com"}
LOG=${X_CHIP_TIME_LOG:-/var/log/x-chip-time-sync.log}

show_ip() {
	if command -v ip >/dev/null 2>&1; then
		ip route 2>/dev/null | sed -n 's/^default /Default route: /p' | head -n 1
		ip addr show 2>/dev/null | sed -n 's/^[[:space:]]*inet \([^ ]*\).* scope global.*/IPv4: \1/p' | head -n 3
	elif command -v route >/dev/null 2>&1; then
		route -n 2>/dev/null | awk '$1 == "0.0.0.0" { print "Default route: " $2; exit }'
		ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([^ ]*\).*/IPv4: \1/p; s/.*inet \([0-9.][0-9.]*\).*/IPv4: \1/p' | head -n 3
	fi
}

network_ready() {
	if command -v ip >/dev/null 2>&1; then
		ip route 2>/dev/null | grep -q '^default '
	elif command -v route >/dev/null 2>&1; then
		route -n 2>/dev/null | awk '$1 == "0.0.0.0" { found = 1 } END { exit found ? 0 : 1 }'
	else
		return 0
	fi
}

run_as_root() {
	if [ "$(id -u)" = 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		echo "Need root privileges." >&2
		return 1
	fi
}

status() {
	echo "Time"
	echo "===="
	date
	echo "UTC: $(TZ=UTC date)"
	echo "TZ: ${TZ:-system default}"
	if pgrep -x ntpd >/dev/null 2>&1; then
		echo "NTP: running"
	else
		echo "NTP: stopped"
	fi
	if [ -e /dev/misc/rtc ] || [ -e /dev/rtc0 ]; then
		echo "RTC: present"
	else
		echo "RTC: not present"
	fi
	show_ip || true
	[ -r "$LOG" ] && {
		echo
		echo "Last sync log:"
		tail -n 8 "$LOG"
	}
}

sync_now() {
	command -v ntpd >/dev/null 2>&1 || {
		echo "NTP unavailable: ntpd is missing." >&2
		return 1
	}
	args=
	for server in $SERVERS; do
		args="$args -p $server"
	done
	echo "Syncing time..."
	echo "Servers:$SERVERS"
	if command -v timeout >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		run_as_root timeout 60 ntpd -nq $args
	else
		# shellcheck disable=SC2086
		run_as_root ntpd -nq $args
	fi
	rc=$?
	echo
	date
	return "$rc"
}

sync_background() {
	(
		i=0
		while [ "$i" -lt 6 ]; do
			if network_ready; then
				sync_now && exit 0
			else
				echo "Waiting for network..."
			fi
			i=$((i + 1))
			sleep 20
		done
		exit 1
	) >"$LOG" 2>&1 &
}

set_manual() {
	value=${*:-}
	if [ -z "$value" ]; then
		echo "Enter date/time."
		echo "Examples:"
		echo "  2026-06-27 14:30:00"
		echo "  062714302026.00"
		printf '> '
		read value || return 1
	fi
	[ -n "$value" ] || return 1
	run_as_root date -s "$value"
	date
}

pause() {
	echo
	echo "Press enter to continue."
	read _ || true
}

menu() {
	while :; do
		clear 2>/dev/null || true
		status
		echo
		echo "1) Sync Internet Time"
		echo "2) Set Date/Time"
		echo "3) Refresh"
		echo "q) Quit"
		printf '> '
		read choice || exit 0
		case "$choice" in
			1) sync_now; pause ;;
			2) set_manual; pause ;;
			3) ;;
			q|Q) exit 0 ;;
		esac
	done
}

case "${1:-menu}" in
	status) status ;;
	sync) sync_now ;;
	sync-background) sync_background ;;
	set) shift; set_manual "$@" ;;
	menu) menu ;;
	*) echo "Usage: x-chip-time [menu|status|sync|sync-background|set VALUE]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-open-image" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME_DIR=${HOME:-/home/chip}

need_viewer() {
	command -v gpicview >/dev/null 2>&1 || {
		echo "Image viewer unavailable: gpicview is not installed." >&2
		exit 1
	}
}

list_images() {
	for dir in "$HOME_DIR/Pictures" "$HOME_DIR/Downloads" "$HOME_DIR"; do
		[ -d "$dir" ] || continue
		find "$dir" -maxdepth 2 -type f \( \
			-name '*.png' -o -name '*.PNG' -o \
			-name '*.jpg' -o -name '*.JPG' -o \
			-name '*.jpeg' -o -name '*.JPEG' -o \
			-name '*.gif' -o -name '*.GIF' -o \
			-name '*.webp' -o -name '*.WEBP' -o \
			-name '*.xpm' -o -name '*.XPM' \) 2>/dev/null
	done | awk '!seen[$0]++'
}

open_file() {
	file=$1
	[ -f "$file" ] || {
		echo "Not a file: $file" >&2
		return 1
	}
	DISPLAY="$DISPLAY" gpicview "$file"
}

status() {
	echo "Image Viewer"
	echo "============"
	command -v gpicview >/dev/null 2>&1 && echo "gpicview: installed" || echo "gpicview: missing"
	count=$(list_images | wc -l | awk '{print $1}')
	echo "Images found: $count"
}

if [ "${1:-}" = status ]; then
	status
	exit 0
fi

need_viewer

if [ "$#" -gt 0 ]; then
	for file in "$@"; do
		open_file "$file"
	done
	exit 0
fi

tmp=/tmp/x-chip-images.$$
trap 'rm -f "$tmp"' EXIT
list_images >"$tmp"
if [ ! -s "$tmp" ]; then
	echo "No image found in Pictures, Downloads, or home."
	printf 'Image path: '
	read file || exit 0
	[ -n "$file" ] && open_file "$file"
	exit 0
fi

echo "Images:"
awk '{ printf "%2d) %s\n", NR, $0 }' "$tmp"
echo
printf 'Open number, or q: '
read choice || exit 0
case "$choice" in
	q|Q|'') exit 0 ;;
	*[!0-9]*) echo "Invalid selection" >&2; exit 2 ;;
esac
file=$(sed -n "${choice}p" "$tmp")
[ -n "$file" ] || {
	echo "Invalid selection" >&2
	exit 2
}
open_file "$file"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-open-pdf" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}

file=${1:-}
[ -n "$file" ] || {
	echo "Usage: x-chip-open-pdf FILE" >&2
	exit 2
}
[ -f "$file" ] || {
	echo "Not a file: $file" >&2
	exit 1
}

for viewer in mupdf epdfview xpdf zathura evince qpdfview; do
	if command -v "$viewer" >/dev/null 2>&1; then
		DISPLAY="$DISPLAY" exec "$viewer" "$file"
	fi
done

msg='No PDF viewer is installed yet.'
if command -v aterm >/dev/null 2>&1; then
	DISPLAY="$DISPLAY" exec aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' \
		-geometry 58x14+0+0 -title PDF -e x-chip-term-hold sh -c \
		'echo "$1"; echo; echo "File:"; echo "$2"' sh "$msg" "$file"
fi

echo "$msg" >&2
echo "$file" >&2
exit 1
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-open" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
export DISPLAY

open_one() {
	target=$1
	case "$target" in
		file://*) target=${target#file://} ;;
	esac

	case "$target" in
		http://*|https://*)
			if command -v dillo >/dev/null 2>&1; then
				exec dillo -g 474x212+0+0 "$target"
			fi
			exec links "$target"
			;;
	esac

	if [ -d "$target" ]; then
		exec pcmanfm "$target"
	fi

	[ -f "$target" ] || {
		echo "Not found: $target" >&2
		return 1
	}

	lower=$(printf '%s\n' "$target" | tr 'A-Z' 'a-z')
	case "$lower" in
		*.png|*.jpg|*.jpeg|*.gif|*.webp|*.xpm)
			exec x-chip-open-image "$target"
			;;
		*.mp4|*.m4v|*.avi|*.mov|*.mkv|*.webm|*.mpg|*.mpeg)
			if command -v aterm >/dev/null 2>&1 && [ ! -t 0 ]; then
				exec aterm -title Video -e x-chip-video play "$target"
			fi
			exec x-chip-video play "$target"
			;;
		*.mp3)
			if command -v aterm >/dev/null 2>&1 && [ ! -t 0 ]; then
				exec aterm -title Music -e x-chip-term-hold x-chip-music play "$target"
			fi
			exec x-chip-music play "$target"
			;;
		*.pdf)
			exec x-chip-open-pdf "$target"
			;;
		*.htm|*.html)
			exec dillo -g 474x212+0+0 "$target"
			;;
		*.txt|*.log|*.md|*.sh|*.conf|*.ini|*.lst)
			exec leafpad "$target"
			;;
	esac

	exec leafpad "$target"
}

[ "$#" -gt 0 ] || {
	echo "Usage: x-chip-open FILE_OR_URL" >&2
	exit 2
}

for target in "$@"; do
	open_one "$target"
done
EOF

    need_root ln -sfn x-chip-open "$RFS/usr/local/bin/xdg-open"

    install_text 0755 "$RFS/usr/local/bin/x-chip-music" <<'EOF'
#!/bin/sh
set -eu

HOME_DIR=${HOME:-/home/chip}
PID_FILE=/tmp/x-chip-music.pid
LOG_FILE=/tmp/x-chip-music.log

load_media() {
	x-chip-media-on mpg123 >/tmp/x-chip-media-on.log 2>&1 || {
		cat /tmp/x-chip-media-on.log >&2 2>/dev/null || true
		return 1
	}
	command -v mpg123 >/dev/null 2>&1 || {
		echo "Music player unavailable: mpg123 is not installed." >&2
		return 1
	}
}

list_music() {
	for dir in "$HOME_DIR/Music" "$HOME_DIR/Downloads" "$HOME_DIR"; do
		[ -d "$dir" ] || continue
		find "$dir" -maxdepth 2 -type f \( -name '*.mp3' -o -name '*.MP3' \) 2>/dev/null
	done | awk '!seen[$0]++'
}

status() {
	echo "Music"
	echo "====="
	command -v mpg123 >/dev/null 2>&1 && echo "mpg123: installed" || echo "mpg123: not loaded"
	count=$(list_music | wc -l | awk '{print $1}')
	echo "MP3 files found: $count"
	echo "Controls in player: s stop, p pause, q quit"
}

play_file() {
	file=$1
	[ -f "$file" ] || {
		echo "Not a file: $file" >&2
		return 1
	}
	pkill -x ffplay 2>/dev/null || killall ffplay 2>/dev/null || true
	load_media
	mpg123 -C "$file"
}

play_background() {
	file=$1
	[ -f "$file" ] || {
		echo "Not a file: $file" >&2
		return 1
	}
	load_media
	pkill -x ffplay 2>/dev/null || killall ffplay 2>/dev/null || true
	pkill -x mpg123 2>/dev/null || killall mpg123 2>/dev/null || true
	nohup mpg123 "$file" >"$LOG_FILE" 2>&1 &
	echo "$!" >"$PID_FILE"
}

case "${1:-menu}" in
	status) status; exit 0 ;;
	stop) pkill -x mpg123 2>/dev/null || killall mpg123 2>/dev/null || true; rm -f "$PID_FILE"; exit 0 ;;
	play) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-music play FILE" >&2; exit 2; }; play_file "$1"; exit $? ;;
	play-bg) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-music play-bg FILE" >&2; exit 2; }; play_background "$1"; exit $? ;;
esac

if [ "$#" -gt 0 ] && [ "$1" != menu ]; then
	play_file "$1"
	exit $?
fi

tmp=/tmp/x-chip-music.$$
trap 'rm -f "$tmp"' EXIT
list_music >"$tmp"
if [ ! -s "$tmp" ]; then
	echo "No MP3 found in Music, Downloads, or home."
	printf 'MP3 path: '
	read file || exit 0
	[ -n "$file" ] && play_file "$file"
	exit 0
fi

echo "Music:"
awk '{ printf "%2d) %s\n", NR, $0 }' "$tmp"
echo
printf 'Play number, or q: '
read choice || exit 0
case "$choice" in
	q|Q|'') exit 0 ;;
	*[!0-9]*) echo "Invalid selection" >&2; exit 2 ;;
esac
file=$(sed -n "${choice}p" "$tmp")
[ -n "$file" ] || {
	echo "Invalid selection" >&2
	exit 2
}
play_file "$file"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-video" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME_DIR=${HOME:-/home/chip}
SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}
export SDL_RENDER_DRIVER

load_media() {
	x-chip-media-on ffmpeg >/tmp/x-chip-media-on.log 2>&1 || {
		cat /tmp/x-chip-media-on.log >&2 2>/dev/null || true
		return 1
	}
	command -v ffplay >/dev/null 2>&1 || {
		echo "Video player unavailable: ffplay is not installed." >&2
		return 1
	}
}

list_videos() {
	{
		default_video="$HOME_DIR/Videos/pocket-video-demo.mp4"
		[ -f "$default_video" ] && printf '%s\n' "$default_video"
		for dir in "$HOME_DIR/Videos" "$HOME_DIR/Downloads" "$HOME_DIR"; do
			[ -d "$dir" ] || continue
			find "$dir" -maxdepth 2 -type f \( \
				-name '*.mp4' -o -name '*.MP4' -o \
				-name '*.m4v' -o -name '*.M4V' -o \
				-name '*.avi' -o -name '*.AVI' -o \
				-name '*.mov' -o -name '*.MOV' -o \
				-name '*.mkv' -o -name '*.MKV' -o \
				-name '*.webm' -o -name '*.WEBM' -o \
				-name '*.mpg' -o -name '*.MPG' -o \
				-name '*.mpeg' -o -name '*.MPEG' \) 2>/dev/null
		done
	} | awk '!seen[$0]++'
}

status() {
	echo "Video"
	echo "====="
	command -v ffplay >/dev/null 2>&1 && echo "ffplay: installed" || echo "ffplay: not loaded"
	count=$(list_videos | wc -l | awk '{print $1}')
	echo "Video files found: $count"
}

play_file() {
	file=$1
	[ -f "$file" ] || {
		echo "Not a file: $file" >&2
		return 1
	}
	load_media
	pkill -x mpg123 2>/dev/null || killall mpg123 2>/dev/null || true
	DISPLAY="$DISPLAY" SDL_RENDER_DRIVER="$SDL_RENDER_DRIVER" \
		ffplay -autoexit -window_title "Video" -x 474 -y 212 "$file"
}

case "${1:-menu}" in
	status) status; exit 0 ;;
	stop) pkill -x ffplay 2>/dev/null || killall ffplay 2>/dev/null || true; exit 0 ;;
	play) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-video play FILE" >&2; exit 2; }; play_file "$1"; exit $? ;;
esac

if [ "$#" -gt 0 ] && [ "$1" != menu ]; then
	play_file "$1"
	exit $?
fi

tmp=/tmp/x-chip-videos.$$
trap 'rm -f "$tmp"' EXIT
list_videos >"$tmp"
if [ ! -s "$tmp" ]; then
	echo "No video found in Videos, Downloads, or home."
	printf 'Video path: '
	read file || exit 0
	[ -n "$file" ] && play_file "$file"
	exit 0
fi

echo "Videos:"
awk '{ printf "%2d) %s\n", NR, $0 }' "$tmp"
echo
printf 'Play number, or q: '
read choice || exit 0
case "$choice" in
	q|Q|'') exit 0 ;;
	*[!0-9]*) echo "Invalid selection" >&2; exit 2 ;;
esac
file=$(sed -n "${choice}p" "$tmp")
[ -n "$file" ] || {
	echo "Invalid selection" >&2
	exit 2
}
play_file "$file"
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/tic80-carts.tsv" <<'EOF'
# slug	title	filename	url	source_page
8-bit-panda	8 Bit Panda	8-bit-panda.tic	https://tic80.com/cart/b88b74e7a6f923251de764d89d6f3507/cart.tic	https://tic80.com/play?cart=188
stele	Stele	stele.tic	https://tic80.com/cart/d00e434d28ec464bf98aa96a4d53cefe/cart.tic	https://tic80.com/play?cart=483
balmung	Balmung	balmung.tic	https://tic80.com/cart/4fb4348371246d26e9eb7f30e89a444d/cart.tic	https://tic80.com/play?cart=636
supernova	Supernova	supernova.tic	https://tic80.com/cart/6e44e8213e39ffb32ec6163f9c595dec/cart.tic	https://tic80.com/play?cart=645
turns-of-war	Turns of War	turns-of-war.tic	https://tic80.com/cart/edd382c230b67b29c728dbcb76422084/cart.tic	https://tic80.com/play?cart=833
cauliflower-power	Cauliflower Power	cauliflower-power.tic	https://tic80.com/cart/74d69f265855b2a8c38ad45116bf48d7/cart.tic	https://tic80.com/play?cart=566
minetic	Minetic	minetic.tic	https://tic80.com/cart/739f92b6c28e237d408c3aa3fe28a521/cart.tic	https://tic80.com/play?cart=665
powder-game	Powder Game	powder-game.tic	https://tic80.com/cart/86883747bfcb2343936428c073bb01d5/cart.tic	https://tic80.com/play?cart=692
secret-agents	Secret Agents	secret-agents.tic	https://tic80.com/cart/2d94108c9eb58d40888501cc4a1ea25c/cart.tic	https://tic80.com/play?cart=548
komet	Komet	komet.tic	https://tic80.com/cart/c35192c128f4bf51041e25efe50da44b/cart.tic	https://tic80.com/play?cart=610
the-sky-house	The Sky House	the-sky-house.tic	https://tic80.com/cart/b43a71cbe200fa37a2e13a7c4f8d7fa4/cart.tic	https://tic80.com/play?cart=328
tic-sweeper	TIC-Sweeper	tic-sweeper.tic	https://tic80.com/cart/807a8e8dc8407ab8ba1e4f687acbb1af/cart.tic	https://tic80.com/play?cart=125
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-tic80" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME_DIR=${HOME:-/home/chip}
MANIFEST=${X_CHIP_TIC80_CARTS_MANIFEST:-/usr/local/share/x-chip/tic80-carts.tsv}
CART_DIR=${X_CHIP_TIC80_CART_DIR:-$HOME_DIR/TIC-80/carts}
TIC80_CONFIG_ROOT=${X_CHIP_TIC80_CONFIG_ROOT:-$HOME_DIR/.local/share/com.nesbox.tic/TIC-80/.local}
TIC80_CONFIG_HASH=${X_CHIP_TIC80_CONFIG_HASH:-be42d6f}
TIC80_SCALE=${X_CHIP_TIC80_SCALE:-2}
TIC80_FULLSCREEN=${X_CHIP_TIC80_FULLSCREEN:-1}
TIC80_POCKET_KEYS=${X_CHIP_TIC80_POCKET_KEYS:-1}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

load_app() {
	if command -v tic80 >/dev/null 2>&1; then
		return 0
	fi
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load tic80.tcz." >&2
		return 1
	fi
	if [ -f /tce/optional/tic80.tcz ]; then
		echo "Loading TIC-80..."
		run_tce_load /tce/optional/tic80.tcz
	else
		echo "tic80.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		return 1
	fi
	command -v tic80 >/dev/null 2>&1 || {
		echo "TIC-80 did not become available after tce-load." >&2
		return 1
	}
}

record_for_slug() {
	slug=$1
	awk -F '	' -v slug="$slug" 'NF >= 4 && $1 !~ /^#/ && $1 == slug { print; found = 1; exit } END { exit found ? 0 : 1 }' "$MANIFEST"
}

slug_for_index() {
	index=$1
	awk -F '	' -v index="$index" 'NF >= 4 && $1 !~ /^#/ { count++; if (count == index) { print $1; found = 1; exit } } END { exit found ? 0 : 1 }' "$MANIFEST"
}

field() {
	printf '%s\n' "$1" | cut -f "$2"
}

cart_path_for() {
	record=$(record_for_slug "$1") || return 1
	file=$(field "$record" 3)
	printf '%s/%s\n' "$CART_DIR" "$file"
}

tls_ready() {
	for bundle in \
		/usr/local/etc/pki/certs/ca-bundle.crt \
		/usr/local/etc/ssl/certs/ca-bundle.crt \
		/usr/local/etc/ssl/certs/ca-certificates.crt \
		/etc/ssl/certs/ca-certificates.crt; do
		[ -s "$bundle" ] && return 0
	done
	return 1
}

download_url() {
	url=$1
	dest=$2
	tmp="$dest.tmp.$$"
	rm -f "$tmp"
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		load_app
	fi
	if command -v curl >/dev/null 2>&1; then
		if ! tls_ready; then
			echo "TLS certificate bundle is missing; HTTPS downloads cannot be verified." >&2
			echo "Rebuild/reflash with the current image or run: sudo /usr/local/tce.installed/ca-certificates" >&2
			return 1
		fi
		curl --retry 2 --connect-timeout 20 -fL -o "$tmp" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$tmp" "$url"
	else
		echo "Need curl or wget to download TIC-80 carts." >&2
		return 1
	fi
	[ -s "$tmp" ] || {
		rm -f "$tmp"
		echo "Downloaded cart is empty." >&2
		return 1
	}
	mv "$tmp" "$dest"
}

install_game() {
	slug=$1
	record=$(record_for_slug "$slug") || {
		echo "Unknown TIC-80 game: $slug" >&2
		return 1
	}
	title=$(field "$record" 2)
	file=$(field "$record" 3)
	url=$(field "$record" 4)
	page=$(field "$record" 5)
	mkdir -p "$CART_DIR"
	dest="$CART_DIR/$file"
	if [ -s "$dest" ]; then
		echo "$title already installed."
		return 0
	fi
	echo "Downloading $title"
	echo "$page"
	download_url "$url" "$dest"
	echo "Installed $dest"
}

install_all() {
	failed=0
	for slug in $(awk -F '	' 'NF >= 4 && $1 !~ /^#/ { print $1 }' "$MANIFEST"); do
		install_game "$slug" || {
			echo "WARN: failed to install $slug" >&2
			failed=1
		}
	done
	return "$failed"
}

write_pocketchip_tic80_options() {
	opt=$1
	mkdir -p "${opt%/*}"
	{
		printf '\000\000\001\001\017\000\000\000\072\073\074\075\034\035\001\023'
		dd if=/dev/zero bs=1 count=36 2>/dev/null
		printf '\001\000\000\000'
	} >"$opt"
}

patch_tic80_options_file() {
	opt=$1
	[ -s "$opt" ] || return 0
	size=$(wc -c <"$opt" 2>/dev/null | tr -d ' ')
	[ "${size:-0}" -ge 16 ] || return 0
	current=$(dd if="$opt" bs=1 skip=12 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
	case "$current" in
		1c1d) return 0 ;;
		1a18) ;;
		*) return 0 ;;
	esac
	printf '\034\035' | dd of="$opt" bs=1 seek=12 conv=notrunc >/dev/null 2>&1 || true
}

ensure_pocketchip_tic80_keys() {
	[ "$TIC80_POCKET_KEYS" = 1 ] || return 0
	if [ -n "$TIC80_CONFIG_HASH" ]; then
		opt="$TIC80_CONFIG_ROOT/$TIC80_CONFIG_HASH/options.dat"
		[ -e "$opt" ] || write_pocketchip_tic80_options "$opt"
	fi
	[ -d "$TIC80_CONFIG_ROOT" ] || return 0
	find "$TIC80_CONFIG_ROOT" -name options.dat -type f 2>/dev/null | while IFS= read -r opt; do
		patch_tic80_options_file "$opt"
	done
}

run_tic80() {
	load_app
	ensure_pocketchip_tic80_keys
	SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}
	export DISPLAY HOME SDL_RENDER_DRIVER
	set -- --skip --soft --scale="$TIC80_SCALE" "$@"
	if [ "$TIC80_FULLSCREEN" = 1 ]; then
		set -- --fullscreen "$@"
	fi
	exec tic80 "$@"
}

list_games() {
	awk -F '	' 'NF >= 4 && $1 !~ /^#/ { printf "%2d) %s\n", ++count, $2 }' "$MANIFEST"
}

play_game() {
	slug=$1
	install_game "$slug"
	cart=$(cart_path_for "$slug")
	run_tic80 --cmd=run "$cart"
}

pause() {
	echo
	echo "Press enter to continue."
	read _ || true
}

menu() {
	while :; do
		clear 2>/dev/null || true
		echo "TIC-80 Games"
		echo "============"
		list_games
		echo
		echo "a) Install all"
		echo "t) Open TIC-80"
		echo "q) Quit"
		printf '> '
		read choice || exit 0
		case "$choice" in
			q|Q) exit 0 ;;
			a|A) install_all || true; pause ;;
			t|T) run_tic80 ;;
			''|*[!0-9]*) echo "Invalid selection"; pause ;;
			*)
				slug=$(slug_for_index "$choice") || {
					echo "Invalid selection"
					pause
					continue
				}
				play_game "$slug"
				;;
		esac
	done
}

case "${1:-menu}" in
	run) run_tic80 ;;
	menu) menu ;;
	list) list_games ;;
	install) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-tic80 install GAME" >&2; exit 2; }; install_game "$1" ;;
	install-all) install_all ;;
	play) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-tic80 play GAME" >&2; exit 2; }; play_game "$1" ;;
	*) echo "Usage: x-chip-tic80 [run|menu|list|install GAME|install-all|play GAME]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-goattracker" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

if ! command -v goattracker >/dev/null 2>&1; then
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load goattracker.tcz." >&2
		exit 1
	fi
	if [ -f /tce/optional/goattracker.tcz ]; then
		echo "Loading GoatTracker..."
		run_tce_load /tce/optional/goattracker.tcz
	else
		echo "goattracker.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		exit 1
	fi
fi

command -v goattracker >/dev/null 2>&1 || {
	echo "GoatTracker did not become available after tce-load." >&2
	exit 1
}

DISPLAY="$DISPLAY" exec goattracker "$@"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-sunvox" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

if ! command -v sunvox >/dev/null 2>&1; then
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load sunvox.tcz." >&2
		exit 1
	fi
	if [ -f /tce/optional/sunvox.tcz ]; then
		echo "Loading SunVox..."
		run_tce_load /tce/optional/sunvox.tcz
	else
		echo "sunvox.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		exit 1
	fi
fi

cmd=sunvox
case "${1:-}" in
	lofi)
		shift
		cmd=sunvox-lofi
		;;
esac

command -v "$cmd" >/dev/null 2>&1 || {
	echo "$cmd did not become available after tce-load." >&2
	exit 1
}

DISPLAY="$DISPLAY" exec "$cmd" "$@"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-virtual-ans" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

if ! command -v virtual-ans >/dev/null 2>&1; then
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load virtual-ans.tcz." >&2
		exit 1
	fi
	if [ -f /tce/optional/virtual-ans.tcz ]; then
		echo "Loading Virtual ANS..."
		run_tce_load /tce/optional/virtual-ans.tcz
	else
		echo "virtual-ans.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		exit 1
	fi
fi

command -v virtual-ans >/dev/null 2>&1 || {
	echo "virtual-ans did not become available after tce-load." >&2
	exit 1
}

DISPLAY="$DISPLAY" exec virtual-ans "$@"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-pixitracker" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

if ! command -v pixitracker >/dev/null 2>&1; then
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load pixitracker.tcz." >&2
		exit 1
	fi
	if [ -f /tce/optional/pixitracker.tcz ]; then
		echo "Loading PixiTracker..."
		run_tce_load /tce/optional/pixitracker.tcz
	else
		echo "pixitracker.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		exit 1
	fi
fi

command -v pixitracker >/dev/null 2>&1 || {
	echo "pixitracker did not become available after tce-load." >&2
	exit 1
}

DISPLAY="$DISPLAY" exec pixitracker "$@"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-pixitracker-1bit" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

if ! command -v pixitracker-1bit >/dev/null 2>&1; then
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load pixitracker-1bit.tcz." >&2
		exit 1
	fi
	if [ -f /tce/optional/pixitracker-1bit.tcz ]; then
		echo "Loading PixiTracker 1Bit..."
		run_tce_load /tce/optional/pixitracker-1bit.tcz
	else
		echo "pixitracker-1bit.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		exit 1
	fi
fi

command -v pixitracker-1bit >/dev/null 2>&1 || {
	echo "pixitracker-1bit did not become available after tce-load." >&2
	exit 1
}

DISPLAY="$DISPLAY" exec pixitracker-1bit "$@"
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-pixilang" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

if ! command -v pixilang >/dev/null 2>&1; then
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load pixilang.tcz." >&2
		exit 1
	fi
	if [ -f /tce/optional/pixilang.tcz ]; then
		echo "Loading Pixilang..."
		run_tce_load /tce/optional/pixilang.tcz
	else
		echo "pixilang.tcz is not cached in /tce/optional." >&2
		echo "Build it with 'make community-tcz' before assembling the image." >&2
		exit 1
	fi
fi

command -v pixilang >/dev/null 2>&1 || {
	echo "pixilang did not become available after tce-load." >&2
	exit 1
}

CONFIG_HOME=${XDG_CONFIG_HOME:-${HOME:-/home/chip}/.config}
CONFIG_DIR=$CONFIG_HOME/Pixilang
if [ -f /usr/local/lib/pixilang/bin/pixilang_config.ini ]; then
	mkdir -p "$CONFIG_DIR"
	cp /usr/local/lib/pixilang/bin/pixilang_config.ini "$CONFIG_DIR/pixilang_config.ini" 2>/dev/null || true
fi

if [ "$#" = 0 ] && [ -x /usr/local/lib/pixilang/bin/pixilang ] && [ -f /usr/local/lib/pixilang/examples/graphics/generator_plasma.pixi ]; then
	cd /usr/local/lib/pixilang/examples/graphics
	DISPLAY="$DISPLAY" exec /usr/local/lib/pixilang/bin/pixilang generator_plasma.pixi
fi

DISPLAY="$DISPLAY" exec pixilang "$@"
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/gameboy-homebrew.tsv" <<'EOF'
# slug	title	filename	url	sha256	license	source_page
2048	2048	2048.gb	https://github.com/wyattferguson/2048-gb/releases/download/v1.1/2048.gb	b8b0ab5dc8159dcd83680a2796010ecf9fc8c94c2cfb9cd3ff30c1998d790aa5	MIT	https://github.com/wyattferguson/2048-gb
ucity	uCity	ucity.gbc	https://github.com/AntonioND/ucity/releases/download/v1.3/ucity.gbc	9422ee2ca7b7ea1d46b58b2a429fff3f354dfd3e732dee1e7ae6220f148ce6e0	GPL-3.0	https://github.com/AntonioND/ucity
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-mgba" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME_DIR=${HOME:-/home/chip}
ROM_DIR=${X_CHIP_MGBA_ROM_DIR:-$HOME_DIR/Games/GameBoy}
MANIFEST=${X_CHIP_MGBA_GAMES_MANIFEST:-/usr/local/share/x-chip/gameboy-homebrew.tsv}
MGBA_CONFIG=${X_CHIP_MGBA_CONFIG:-$HOME_DIR/.config/mgba/config.ini}
MGBA_POCKET_KEYS=${X_CHIP_MGBA_POCKET_KEYS:-1}
MGBA_FULLSCREEN=${X_CHIP_MGBA_FULLSCREEN:-1}
MGBA_WIDTH=${X_CHIP_MGBA_WIDTH:-480}
MGBA_HEIGHT=${X_CHIP_MGBA_HEIGHT:-272}
MGBA_LOCK_ASPECT=${X_CHIP_MGBA_LOCK_ASPECT:-0}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

find_mgba() {
	if [ -n "${X_CHIP_MGBA_BIN:-}" ] && [ -x "$X_CHIP_MGBA_BIN" ]; then
		printf '%s\n' "$X_CHIP_MGBA_BIN"
		return 0
	fi
	if command -v mgba-sdl1 >/dev/null 2>&1; then
		command -v mgba-sdl1
		return 0
	fi
	command -v mgba 2>/dev/null || return 1
}

load_app() {
	if find_mgba >/dev/null 2>&1; then
		return 0
	fi
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load mgba.tcz." >&2
		return 1
	fi
	if [ -f /tce/optional/mgba.tcz ]; then
		echo "Loading mGBA..."
		run_tce_load /tce/optional/mgba.tcz
	else
		echo "mgba.tcz is not cached in /tce/optional." >&2
		echo "Build it with './scripts/09-build-community-tcz.sh mgba' before assembling the image." >&2
		return 1
	fi
	find_mgba >/dev/null 2>&1 || {
		echo "mGBA did not become available after tce-load." >&2
		return 1
	}
}

record_for_slug() {
	slug=$1
	awk -F '	' -v slug="$slug" 'NF >= 7 && $1 !~ /^#/ && $1 == slug { print; found = 1; exit } END { exit found ? 0 : 1 }' "$MANIFEST"
}

slug_for_index() {
	index=$1
	awk -F '	' -v index="$index" 'NF >= 7 && $1 !~ /^#/ { count++; if (count == index) { print $1; found = 1; exit } } END { exit found ? 0 : 1 }' "$MANIFEST"
}

field() {
	printf '%s\n' "$1" | cut -f "$2"
}

rom_path_for_slug() {
	record=$(record_for_slug "$1") || return 1
	file=$(field "$record" 3)
	printf '%s/%s\n' "$ROM_DIR" "$file"
}

tls_ready() {
	for bundle in \
		/usr/local/etc/pki/certs/ca-bundle.crt \
		/usr/local/etc/ssl/certs/ca-bundle.crt \
		/usr/local/etc/ssl/certs/ca-certificates.crt \
		/etc/ssl/certs/ca-certificates.crt; do
		[ -s "$bundle" ] && return 0
	done
	return 1
}

verify_sha256() {
	file=$1
	expected=$2
	[ -n "$expected" ] || return 0
	if ! command -v sha256sum >/dev/null 2>&1; then
		echo "sha256sum is missing; cannot verify downloaded ROM." >&2
		return 1
	fi
	actual=$(sha256sum "$file" | awk '{ print $1 }')
	[ "$actual" = "$expected" ] || {
		echo "SHA-256 mismatch for $file" >&2
		echo "expected: $expected" >&2
		echo "actual:   $actual" >&2
		return 1
	}
}

download_url() {
	url=$1
	dest=$2
	sha256=$3
	tmp="$dest.tmp.$$"
	rm -f "$tmp"
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		load_app
	fi
	if command -v curl >/dev/null 2>&1; then
		if ! tls_ready; then
			echo "TLS certificate bundle is missing; HTTPS downloads cannot be verified." >&2
			echo "Rebuild/reflash with the current image or run: sudo /usr/local/tce.installed/ca-certificates" >&2
			return 1
		fi
		curl --retry 2 --connect-timeout 20 -fL -o "$tmp" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$tmp" "$url"
	else
		echo "Need curl or wget to download Game Boy homebrew." >&2
		return 1
	fi
	[ -s "$tmp" ] || {
		rm -f "$tmp"
		echo "Downloaded ROM is empty." >&2
		return 1
	}
	verify_sha256 "$tmp" "$sha256" || {
		rm -f "$tmp"
		return 1
	}
	mv "$tmp" "$dest"
}

install_game() {
	slug=$1
	record=$(record_for_slug "$slug") || {
		echo "Unknown Game Boy homebrew: $slug" >&2
		return 1
	}
	title=$(field "$record" 2)
	file=$(field "$record" 3)
	url=$(field "$record" 4)
	sha256=$(field "$record" 5)
	license=$(field "$record" 6)
	page=$(field "$record" 7)
	case "$file" in
		*/*|'') echo "Invalid ROM filename in manifest: $file" >&2; return 1 ;;
	esac
	mkdir -p "$ROM_DIR"
	dest="$ROM_DIR/$file"
	if [ -s "$dest" ]; then
		if verify_sha256 "$dest" "$sha256"; then
			echo "$title already installed."
			return 0
		fi
		echo "Replacing corrupt or outdated $dest"
		rm -f "$dest"
	fi
	echo "Downloading $title ($license)"
	echo "$page"
	download_url "$url" "$dest" "$sha256"
	echo "Installed $dest"
}

install_all() {
	failed=0
	for slug in $(awk -F '	' 'NF >= 7 && $1 !~ /^#/ { print $1 }' "$MANIFEST"); do
		install_game "$slug" || {
			echo "WARN: failed to install $slug" >&2
			failed=1
		}
	done
	return "$failed"
}

list_homebrew() {
	awk -F '	' 'NF >= 7 && $1 !~ /^#/ { printf "%2d) %s [%s]\n", ++count, $2, $6 }' "$MANIFEST"
}

ensure_mgba_pocket_config() {
	[ "$MGBA_POCKET_KEYS" = 1 ] || [ "$MGBA_FULLSCREEN" = 1 ] || return 0
	mkdir -p "${MGBA_CONFIG%/*}"
	tmp="$MGBA_CONFIG.tmp.$$"
	out="$MGBA_CONFIG.new.$$"
	if [ -f "$MGBA_CONFIG" ]; then
		awk '
			BEGIN { in_section = 0; in_input = 0 }
			/^\[/ { in_section = 1; in_input = 0 }
			/^\[gba\.input\.KEY\]$/ { in_input = 1; print; next }
			!in_section && /^(fullscreen|width|height|lockAspectRatio|lockIntegerScaling|resampleVideo)=/ { next }
			in_input && /^keyA=/ { next }
			in_input && /^keyB=/ { next }
			in_input && /^keySelect=/ { next }
			in_input && /^keyStart=/ { next }
			{ print }
		' "$MGBA_CONFIG" >"$tmp"
	else
		: >"$tmp"
	fi
	{
		printf 'fullscreen=%s\n' "$MGBA_FULLSCREEN"
		printf 'width=%s\n' "$MGBA_WIDTH"
		printf 'height=%s\n' "$MGBA_HEIGHT"
		printf 'lockAspectRatio=%s\n' "$MGBA_LOCK_ASPECT"
		printf 'lockIntegerScaling=0\n'
		printf 'resampleVideo=0\n'
		cat "$tmp"
	} >"$out"
	mv "$out" "$tmp"
	if ! grep -qxF '[gba.input.KEY]' "$tmp"; then
		printf '\n[gba.input.KEY]\n' >>"$tmp"
	fi
	awk '
		BEGIN { in_section = 0 }
		{
			print
			if ($0 == "[gba.input.KEY]") {
				in_section = 1
				print "keyA=49"
				print "keyB=50"
				print "keySelect=8"
				print "keyStart=13"
				next
			}
			if (in_section && $0 ~ /^\[/) in_section = 0
		}
	' "$tmp" >"$MGBA_CONFIG"
	rm -f "$tmp" "$out"
}

list_roms() {
	for dir in "$ROM_DIR" "$HOME_DIR/Downloads" "$HOME_DIR"; do
		[ -d "$dir" ] || continue
		find "$dir" -maxdepth 2 -type f \( \
			-name '*.gb' -o -name '*.GB' -o \
			-name '*.gbc' -o -name '*.GBC' -o \
			-name '*.gba' -o -name '*.GBA' \) 2>/dev/null
	done | awk '!seen[$0]++'
}

run_mgba() {
	cmd=$(find_mgba) || {
		echo "mGBA is not available." >&2
		return 1
	}
	SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-x11}
	SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}
	export DISPLAY SDL_VIDEODRIVER SDL_AUDIODRIVER
	"$cmd" -1 \
		-C "fullscreen=$MGBA_FULLSCREEN" \
		-C "width=$MGBA_WIDTH" \
		-C "height=$MGBA_HEIGHT" \
		-C "lockAspectRatio=$MGBA_LOCK_ASPECT" \
		-C "lockIntegerScaling=0" \
		-C "resampleVideo=0" \
		"$@"
}

play_file() {
	file=$1
	[ -f "$file" ] || {
		echo "Not a file: $file" >&2
		return 1
	}
	load_app
	ensure_mgba_pocket_config
	run_mgba "$file"
}

play_game() {
	slug=$1
	install_game "$slug"
	rom=$(rom_path_for_slug "$slug")
	play_file "$rom"
}

play_target() {
	target=$1
	if [ -f "$target" ]; then
		play_file "$target"
	elif record_for_slug "$target" >/dev/null 2>&1; then
		play_game "$target"
	else
		play_file "$target"
	fi
}

status() {
	echo "mGBA"
	echo "===="
	if cmd=$(find_mgba); then
		echo "binary: $cmd"
	else
		echo "binary: not loaded"
	fi
	[ -f /tce/optional/mgba.tcz ] && echo "mgba.tcz: cached" || echo "mgba.tcz: missing"
	echo "ROM directory: $ROM_DIR"
	count=$(list_roms | wc -l | awk '{print $1}')
	echo "ROMs found: $count"
	echo
	echo "Public homebrew:"
	list_homebrew
	echo
	echo "Public homebrew downloads on first launch. You can also put legal .gb, .gbc, or .gba files in:"
	echo "$ROM_DIR"
}

browse_local_roms() {
	mkdir -p "$ROM_DIR"
	tmp=/tmp/x-chip-mgba-roms.$$
	trap 'rm -f "$tmp"' EXIT
	list_roms >"$tmp"
	if [ ! -s "$tmp" ]; then
		status
		echo
		printf 'ROM path, or q: '
		read file || exit 0
		case "$file" in q|Q|'') exit 0 ;; esac
		play_file "$file"
		exit $?
	fi

	echo "Local mGBA ROMs:"
	awk '{
		name = $0
		sub(".*/", "", name)
		printf "%2d) %s\n    %s\n", NR, name, $0
	}' "$tmp"
	echo
	printf 'Play number, Enter for first, p for path, or q: '
	read choice || exit 0
	case "$choice" in
		q|Q) exit 0 ;;
		'') choice=1 ;;
		p|P)
			printf 'ROM path: '
			read file || exit 0
			[ -n "$file" ] || exit 0
			play_file "$file"
			exit $?
			;;
		*[!0-9]*) echo "Invalid selection" >&2; exit 2 ;;
	esac
	file=$(sed -n "${choice}p" "$tmp")
	[ -n "$file" ] || {
		echo "Invalid selection" >&2
		exit 2
	}
	play_file "$file"
}

pause() {
	echo
	echo "Press enter to continue."
	read _ || true
}

menu() {
	while :; do
		clear 2>/dev/null || true
		echo "Game Boy Homebrew"
		echo "================="
		list_homebrew
		echo
		echo "a) Install all homebrew"
		echo "l) Local ROM browser"
		echo "s) Status"
		echo "q) Quit"
		printf '> '
		read choice || exit 0
		case "$choice" in
			q|Q) exit 0 ;;
			a|A) install_all || true; pause ;;
			l|L) browse_local_roms; pause ;;
			s|S) status; pause ;;
			''|*[!0-9]*) echo "Invalid selection"; pause ;;
			*)
				slug=$(slug_for_index "$choice") || {
					echo "Invalid selection"
					pause
					continue
				}
				play_game "$slug"
				;;
		esac
	done
}

case "${1:-menu}" in
	status) status ;;
	run) shift; if [ "$#" -gt 0 ]; then play_target "$1"; else menu; fi ;;
	menu) menu ;;
	list|list-homebrew) list_homebrew ;;
	install) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-mgba install GAME" >&2; exit 2; }; install_game "$1" ;;
	install-all) install_all ;;
	play) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-mgba play GAME_OR_ROM" >&2; exit 2; }; play_target "$1" ;;
	*) play_target "$1" ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-pico8" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME_DIR=${HOME:-/home/chip}
WINDOW_ARGS="-windowed 1 -width 480 -height 272"

find_pico8() {
	if [ -n "${X_CHIP_PICO8_BIN:-}" ] && [ -x "$X_CHIP_PICO8_BIN" ]; then
		printf '%s\n' "$X_CHIP_PICO8_BIN"
		return 0
	fi
	for bin in \
		"$HOME_DIR/pico-8/pico8" \
		"$HOME_DIR/pico8/pico8" \
		"/opt/pico-8/pico8" \
		"/usr/local/bin/pico8"; do
		[ -x "$bin" ] || continue
		printf '%s\n' "$bin"
		return 0
	done
	command -v pico8 2>/dev/null || return 1
}

missing() {
	echo "PICO-8 is not bundled with this image."
	echo
	echo "Install your licensed Linux ARM PICO-8 files in one of:"
	echo "  $HOME_DIR/pico-8/pico8"
	echo "  $HOME_DIR/pico8/pico8"
	echo "  /opt/pico-8/pico8"
	echo
	echo "Or set X_CHIP_PICO8_BIN to the pico8 executable."
}

status() {
	echo "PICO-8"
	echo "======"
	if bin=$(find_pico8); then
		echo "binary: $bin"
	else
		echo "binary: missing"
	fi
	echo "mode: windowed 480x272"
}

run_pico8() {
	bin=$(find_pico8) || {
		missing >&2
		return 1
	}
	export DISPLAY
	# shellcheck disable=SC2086
	exec "$bin" $WINDOW_ARGS "$@"
}

menu() {
	while :; do
		clear 2>/dev/null || true
		status
		echo
		echo "1) Splore"
		echo "2) Run cart path"
		echo "q) Quit"
		printf '> '
		read choice || exit 0
		case "$choice" in
			q|Q|'') exit 0 ;;
			1) run_pico8 -splore ;;
			2)
				printf 'Cart path: '
				read cart || exit 0
				[ -n "$cart" ] || continue
				run_pico8 "$cart"
				;;
			*) echo "Invalid selection"; sleep 1 ;;
		esac
	done
}

case "${1:-menu}" in
	status) status ;;
	run|splore) run_pico8 -splore ;;
	play) shift; [ "$#" -gt 0 ] || { echo "Usage: x-chip-pico8 play CART" >&2; exit 2; }; run_pico8 "$1" ;;
	menu) menu ;;
	*) echo "Usage: x-chip-pico8 [menu|status|run|splore|play CART]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-games" <<'EOF'
#!/bin/sh
set -eu

pause() {
	echo
	echo "Press enter to continue."
	read _ || true
}

status() {
	echo "Game Launchers"
	echo "=============="
	echo
	x-chip-mgba status || true
	echo
	x-chip-doom status || true
	echo
	x-chip-pico8 status || true
	echo
	command -v tic80 >/dev/null 2>&1 && echo "TIC-80: loaded" || echo "TIC-80: lazy-load"
	command -v goattracker >/dev/null 2>&1 && echo "GoatTracker: loaded" || echo "GoatTracker: lazy-load"
}

menu() {
	while :; do
		clear 2>/dev/null || true
		echo "Games"
		echo "====="
		echo "1) Game Boy / Game Boy Advance"
		echo "2) Doom"
		echo "3) TIC-80"
		echo "4) PICO-8"
		echo "5) GoatTracker"
		echo "s) Status"
		echo "q) Quit"
		printf '> '
		read choice || exit 0
		case "$choice" in
			q|Q|'') exit 0 ;;
			1) x-chip-mgba menu; pause ;;
			2) x-chip-doom run; pause ;;
			3) x-chip-tic80 menu; pause ;;
			4) x-chip-pico8 menu; pause ;;
			5) x-chip-goattracker; pause ;;
			s|S) status; pause ;;
			*) echo "Invalid selection"; sleep 1 ;;
		esac
	done
}

case "${1:-menu}" in
	menu) menu ;;
	status) status ;;
	gameboy|gb|gba) exec x-chip-mgba menu ;;
	doom) exec x-chip-doom run ;;
	tic80|tic-80|tic) exec x-chip-tic80 menu ;;
	pico8|pico-8|pico) exec x-chip-pico8 menu ;;
	goattracker|goat) exec x-chip-goattracker ;;
	*) echo "Usage: x-chip-games [menu|status|gameboy|doom|tic80|pico8|goattracker]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-doom" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME=${HOME:-/home/chip}
IWAD=${X_CHIP_DOOM_IWAD:-/usr/local/share/doom/freedoom1.wad}
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"

run_tce_load() {
	target=$1
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

load_app() {
	if command -v chocolate-doom >/dev/null 2>&1; then
		return 0
	fi
	if ! command -v tce-load >/dev/null 2>&1; then
		echo "tce-load is missing; cannot load doom.tcz." >&2
		return 1
	fi
	if [ -f /tce/optional/doom.tcz ]; then
		echo "Loading Doom..."
		run_tce_load /tce/optional/doom.tcz
	else
		echo "doom.tcz is not cached in /tce/optional." >&2
		echo "Build it with './scripts/09-build-community-tcz.sh doom' before assembling the image." >&2
		return 1
	fi
	command -v chocolate-doom >/dev/null 2>&1 || {
		echo "Chocolate Doom did not become available after tce-load." >&2
		return 1
	}
}

status() {
	echo "Doom"
	echo "===="
	command -v chocolate-doom >/dev/null 2>&1 && echo "chocolate-doom: installed" || echo "chocolate-doom: not loaded"
	[ -f /tce/optional/doom.tcz ] && echo "doom.tcz: cached" || echo "doom.tcz: missing"
	[ -f "$IWAD" ] && echo "IWAD: $IWAD" || echo "IWAD missing: $IWAD"
}

run_game() {
	load_app
	[ -f "$IWAD" ] || {
		echo "Missing Doom IWAD: $IWAD" >&2
		return 1
	}
	SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-x11}
	export DISPLAY HOME SDL_VIDEODRIVER
	if [ "${X_CHIP_DOOM_SOUND:-0}" = 1 ]; then
		exec chocolate-doom -iwad "$IWAD" -fullscreen "$@"
	fi
	SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}
	export SDL_AUDIODRIVER
	exec chocolate-doom -iwad "$IWAD" -fullscreen -nosound -nomusic "$@"
}

case "${1:-run}" in
	status) status ;;
	run) shift; run_game "$@" ;;
	*) run_game "$@" ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-desktop-stats" <<'EOF'
#!/bin/sh
set -eu

DISPLAY=${DISPLAY:-:0}
HOME_DIR=${HOME:-/home/chip}
CONFIG=${X_CHIP_CONKY_CONFIG:-$HOME_DIR/.conkyrc}
STATE_CONFIG=${X_CHIP_DESKTOP_STATS_CONFIG:-/usr/local/etc/x-chip/desktop-stats.conf}

ensure_conky() {
	if command -v conky >/dev/null 2>&1; then
		return 0
	fi
	if command -v tce-load >/dev/null 2>&1; then
		if [ -f /tce/optional/conky.tcz ]; then
			tce-load -il /tce/optional/conky.tcz >/tmp/x-chip-conky-load.log 2>&1 || true
		else
			tce-load -il conky.tcz >/tmp/x-chip-conky-load.log 2>&1 || true
		fi
	fi
	command -v conky >/dev/null 2>&1 || {
		echo "Desktop stats unavailable: conky is not installed." >&2
		return 1
	}
}

save_state() {
	enabled=$1
	case "$enabled" in
		1|yes|true|on) enabled=1 ;;
		*) enabled=0 ;;
	esac
	tmp=/tmp/x-chip-desktop-stats.conf.$$
	{
		echo "X_CHIP_DESKTOP_STATS=$enabled"
	} >"$tmp"
	if [ "$(id -u)" = 0 ]; then
		mkdir -p "$(dirname "$STATE_CONFIG")"
		install -m644 "$tmp" "$STATE_CONFIG"
	elif command -v sudo >/dev/null 2>&1; then
		sudo mkdir -p "$(dirname "$STATE_CONFIG")"
		sudo install -m644 "$tmp" "$STATE_CONFIG"
	else
		echo "Cannot save $STATE_CONFIG without root" >&2
		rm -f "$tmp"
		return 1
	fi
	rm -f "$tmp"
	if command -v filetool.sh >/dev/null 2>&1; then
		filetool.sh -b >/tmp/x-chip-desktop-stats-filetool.log 2>&1 || true
	fi
}

load_state() {
	[ -r "$STATE_CONFIG" ] || return 1
	sed -n 's/^X_CHIP_DESKTOP_STATS=\([^#[:space:]]*\).*$/\1/p' "$STATE_CONFIG" | head -n 1
}

state_enabled() {
	value=$(load_state 2>/dev/null || true)
	case "$value" in
		1|yes|true|on) return 0 ;;
		*) return 1 ;;
	esac
}

write_config() {
	mkdir -p "$HOME_DIR"
	cat >"$CONFIG" <<'CONKY'
conky.config = {
	background = false,
	update_interval = 5,
	total_run_times = 0,
	double_buffer = true,
	use_xft = true,
	font = 'Luxi Sans:size=8',
	own_window = false,
	alignment = 'top_left',
	gap_x = 6,
	gap_y = 38,
	minimum_width = 190,
	maximum_width = 220,
	draw_shades = false,
	draw_outline = false,
	draw_borders = false,
	draw_graph_borders = false,
	default_color = 'EAF2EF',
	color1 = '4FD1C5',
	color2 = '1F7A66',
};

conky.text = [[
${color1}${time %a %d %b  %H:%M}${color}
${color1}Pocket${color} ${nodename}
Up ${uptime_short}  Load ${loadavg}
CPU ${cpu cpu0}% ${freq_g}GHz
RAM ${memperc}% ${mem}/${memmax}
Disk ${fs_used /}/${fs_size /}
WiFi ${addr wlan0}
Bat ${execi 10 sh -c "cat /sys/class/power_supply/*/capacity 2>/dev/null | head -n 1"}% ${execi 10 sh -c "cat /sys/class/power_supply/*/status 2>/dev/null | head -n 1"}
]];
CONKY
}

is_running() {
	pgrep -x conky >/dev/null 2>&1
}

start_stats() {
	persist=${1:-1}
	ensure_conky || return 1
	write_config
	if is_running; then
		echo "Desktop stats already on"
		[ "$persist" = 1 ] && save_state 1 || true
		return 0
	fi
	DISPLAY="$DISPLAY" conky -c "$CONFIG" -d >/tmp/x-chip-conky.log 2>&1
	[ "$persist" = 1 ] && save_state 1 || true
	echo "Desktop stats on"
}

stop_stats() {
	persist=${1:-1}
	pkill -x conky 2>/dev/null || killall conky 2>/dev/null || true
	[ "$persist" = 1 ] && save_state 0 || true
	echo "Desktop stats off"
}

restore_stats() {
	if state_enabled; then
		start_stats 0 || true
	else
		stop_stats 0 >/dev/null 2>&1 || true
	fi
}

status() {
	echo "Desktop Stats"
	echo "============="
	if is_running; then
		echo "Status: on"
	else
		echo "Status: off"
	fi
	echo "Config: $CONFIG"
	saved=$(load_state 2>/dev/null || true)
	case "$saved" in
		1|yes|true|on) saved=on ;;
		0|no|false|off) saved=off ;;
		*) saved=unset ;;
	esac
	echo "Saved: $saved"
	echo "State config: $STATE_CONFIG"
	command -v conky >/dev/null 2>&1 && conky -v 2>/dev/null | sed -n '1p' || echo "conky: not loaded"
}

case "${1:-toggle}" in
	on|start) start_stats ;;
	off|stop) stop_stats ;;
	apply|restore|boot) restore_stats ;;
	toggle)
		if is_running; then
			stop_stats
		else
			start_stats
		fi
		;;
	status) status ;;
	*) echo "Usage: x-chip-desktop-stats [on|off|toggle|restore|status]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-logs" <<'EOF'
#!/bin/sh
set -eu

show_file() {
	file=$1
	lines=${2:-80}
	echo
	echo "== $file =="
	if [ -r "$file" ]; then
		tail -n "$lines" "$file"
	else
		echo "not available"
	fi
}

case "${1:-all}" in
	boot) show_file /opt/x-chip-boot.log 140 ;;
	desktop) show_file /var/log/x-chip-desktop.log 140 ;;
	xorg)
		show_file /tmp/x-chip-startx.log 100
		show_file /tmp/x-chip-xorg.log 140
		show_file /tmp/Xorg.0.log 160
		show_file /tmp/x-chip-x-calibration.log 80
		;;
	wifi)
		show_file /var/log/wpa_supplicant.log 120
		for f in /var/log/dhcpcd-*.log /var/log/udhcpc-*.log; do
			[ -e "$f" ] && show_file "$f" 80
		done
		;;
	system)
		echo "== dmesg =="
		dmesg | tail -n 140
		;;
	all)
		show_file /opt/x-chip-boot.log 120
		show_file /var/log/x-chip-desktop.log 120
		show_file /tmp/x-chip-startx.log 80
		show_file /tmp/x-chip-xorg.log 100
		show_file /tmp/Xorg.0.log 100
		show_file /var/log/wpa_supplicant.log 80
		show_file /tmp/x-chip-brightness.log 40
		echo
		echo "== dmesg =="
		dmesg | tail -n 80
		;;
	*) echo "Usage: x-chip-logs [all|boot|desktop|xorg|wifi|system]" >&2; exit 2 ;;
esac

echo
echo "Press enter to close."
read _ || true
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-brightness" <<'EOF'
#!/bin/sh
set -eu

CONFIG=${X_CHIP_DISPLAY_CONFIG:-/usr/local/etc/x-chip/display.conf}
MIN_BRIGHTNESS=${X_CHIP_MIN_BRIGHTNESS:-1}

case "$MIN_BRIGHTNESS" in
	''|*[!0-9]*) MIN_BRIGHTNESS=1 ;;
esac

find_backlight() {
	for p in /sys/class/backlight/*; do
		[ -d "$p" ] || continue
		[ -r "$p/max_brightness" ] || continue
		printf '%s\n' "$p"
		return 0
	done
	return 1
}

read_num() {
	sed -n '1{s/[^0-9].*$//; /^[0-9][0-9]*$/p;}' "$1" 2>/dev/null
}

write_value() {
	path=$1
	write_value_value=$2
	if [ -w "$path" ]; then
		printf '%s\n' "$write_value_value" >"$path"
	elif command -v sudo >/dev/null 2>&1; then
		printf '%s\n' "$write_value_value" | sudo tee "$path" >/dev/null
	else
		echo "Need root to write $path" >&2
		return 1
	fi
}

save_config() {
	value=$1
	case "$value" in
		''|*[!0-9]*) value=$MIN_BRIGHTNESS ;;
	esac
	[ "$value" -lt "$MIN_BRIGHTNESS" ] && value=$MIN_BRIGHTNESS
	tmp=/tmp/x-chip-display.conf.$$
	{
		echo "LCD_BRIGHTNESS=$value"
	} >"$tmp"
	if [ "$(id -u)" = 0 ]; then
		mkdir -p "$(dirname "$CONFIG")"
		install -m644 "$tmp" "$CONFIG"
	elif command -v sudo >/dev/null 2>&1; then
		sudo mkdir -p "$(dirname "$CONFIG")"
		sudo install -m644 "$tmp" "$CONFIG"
	else
		echo "Cannot save $CONFIG without root" >&2
		rm -f "$tmp"
		return 1
	fi
	rm -f "$tmp"
	if command -v filetool.sh >/dev/null 2>&1; then
		filetool.sh -b >/tmp/x-chip-brightness-filetool.log 2>&1 || true
	fi
}

load_saved() {
	[ -r "$CONFIG" ] || return 1
	sed -n 's/^LCD_BRIGHTNESS=\([0-9][0-9]*\)$/\1/p' "$CONFIG" | head -n 1
}

clamp() {
	value=$1
	max=$2
	min=$MIN_BRIGHTNESS
	[ "$max" -lt "$min" ] && min="$max"
	[ "$value" -lt "$min" ] && value=$min
	[ "$value" -gt "$max" ] && value=$max
	printf '%s\n' "$value"
}

apply_value() {
	value=$1
	bl=$(find_backlight) || {
		echo "No backlight device found" >&2
		return 1
	}
	max=$(read_num "$bl/max_brightness")
	current=$(read_num "$bl/brightness")
	[ -n "$max" ] || max=8
	[ -n "$current" ] || current=0
	value=$(clamp "$value" "$max")
	[ -w "$bl/bl_power" ] || [ "$(id -u)" = 0 ] || command -v sudo >/dev/null 2>&1 || true
	[ -e "$bl/bl_power" ] && write_value "$bl/bl_power" 0 2>/dev/null || true
	write_value "$bl/brightness" "$value"
	echo "Brightness: $value/$max"
}

status() {
	bl=$(find_backlight) || {
		echo "No backlight device found"
		return 0
	}
	max=$(read_num "$bl/max_brightness")
	current=$(read_num "$bl/brightness")
	saved=$(load_saved 2>/dev/null || true)
	echo "Backlight: ${bl##*/}"
	echo "Brightness: ${current:-?}/${max:-?}"
	[ -n "$saved" ] && echo "Saved: $saved"
}

step_value() {
	bl=$(find_backlight) || exit 1
	max=$(read_num "$bl/max_brightness")
	current=$(read_num "$bl/brightness")
	[ -n "$max" ] || max=8
	[ -n "$current" ] || current=0
	step=$((max / 8))
	[ "$step" -lt 1 ] && step=1
	case "$1" in
		up) next=$((current + step)) ;;
		down) next=$((current - step)) ;;
	esac
	next=$(clamp "$next" "$max")
	apply_value "$next"
	save_config "$next" || true
}

menu() {
	while :; do
		clear 2>/dev/null || true
		status
		echo
		echo "1) Dim (min $MIN_BRIGHTNESS)"
		echo "2) Brighter"
		echo "3) Set value ($MIN_BRIGHTNESS-max)"
		echo "4) Apply saved"
		echo "5) Default 6"
		echo "q) Quit"
		printf '> '
		read choice || exit 0
		case "$choice" in
			1) step_value down ;;
			2) step_value up ;;
			3)
				printf 'Brightness value: '
				read value || continue
				case "$value" in
					''|*[!0-9]*) echo "Invalid value"; sleep 1; continue ;;
				esac
				[ "$value" -lt "$MIN_BRIGHTNESS" ] && value=$MIN_BRIGHTNESS
				apply_value "$value"
				save_config "$value" || true
				;;
			4)
				value=$(load_saved 2>/dev/null || true)
				[ -n "$value" ] && apply_value "$value" || echo "No saved value"
				;;
			5)
				apply_value 6
				save_config 6 || true
				;;
			q|Q) exit 0 ;;
		esac
		sleep 1
	done
}

cmd=${1:-status}
case "$cmd" in
	up|+) step_value up ;;
	down|-) step_value down ;;
	set)
		value=${2:-}
		case "$value" in
			''|*[!0-9]*) echo "Usage: x-chip-brightness set VALUE" >&2; exit 2 ;;
		esac
		[ "$value" -lt "$MIN_BRIGHTNESS" ] && value=$MIN_BRIGHTNESS
		apply_value "$value"
		save_config "$value" || true
		;;
	apply)
		value=$(load_saved 2>/dev/null || true)
		[ -n "$value" ] || value=${LCD_BRIGHTNESS:-6}
		apply_value "$value"
		;;
	menu) menu ;;
	status) status ;;
	*) echo "Usage: x-chip-brightness [status|up|down|set VALUE|apply|menu]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-wifi-menu" <<'EOF'
#!/bin/sh
set -eu

COUNTRY=${WIFI_COUNTRY:-PT}
HOSTNAME_VALUE=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo chip)
CONF=${X_CHIP_WIFI_CONFIG:-/etc/wpa_supplicant.conf}
ROLE_CONFIG=${X_CHIP_WIFI_ROLE_CONFIG:-/usr/local/etc/x-chip/wifi.conf}
CLIENT_DRIVER=rtl8723bs
SCAN_DRIVER=rtl8812au

[ -r "$ROLE_CONFIG" ] && . "$ROLE_CONFIG"
CLIENT_DRIVER=${X_CHIP_WIFI_CLIENT_DRIVER:-$CLIENT_DRIVER}
SCAN_DRIVER=${X_CHIP_WIFI_SCAN_DRIVER:-$SCAN_DRIVER}
CLIENT_IFACE=${X_CHIP_WIFI_CLIENT_IFACE:-}
SCAN_IFACE=${X_CHIP_WIFI_SCAN_IFACE:-}

all_wifi_ifaces() {
	for iface_path in /sys/class/net/wlan* /sys/class/net/wlp*; do
		[ -e "$iface_path" ] || continue
		iface=${iface_path##*/}
		case "$iface" in *mon) continue ;; esac
		printf '%s\n' "$iface"
	done
}

iface_driver() {
	iface=$1
	driver=
	if [ -r "/sys/class/net/$iface/device/uevent" ]; then
		driver=$(sed -n 's/^DRIVER=//p' "/sys/class/net/$iface/device/uevent" | head -n 1)
	fi
	if [ -z "$driver" ] && [ -L "/sys/class/net/$iface/device/driver" ]; then
		driver_path=$(readlink "/sys/class/net/$iface/device/driver" 2>/dev/null || true)
		driver=${driver_path##*/}
	fi
	printf '%s\n' "$driver"
}

default_route_iface() {
	if command -v ip >/dev/null 2>&1; then
		ip route 2>/dev/null | awk '$1 == "default" { print $5; exit }'
	else
		route -n 2>/dev/null | awk '$1 == "0.0.0.0" { print $8; exit }'
	fi
}

find_iface_by_driver() {
	want=$1
	[ -n "$want" ] || return 1
	for iface in $(all_wifi_ifaces); do
		[ "$(iface_driver "$iface")" = "$want" ] || continue
		printf '%s\n' "$iface"
		return 0
	done
	return 1
}

find_client_wifi_iface() {
	if [ -n "$CLIENT_IFACE" ] && [ -e "/sys/class/net/$CLIENT_IFACE" ]; then
		printf '%s\n' "$CLIENT_IFACE"
		return 0
	fi
	find_iface_by_driver "$CLIENT_DRIVER" && return 0
	route_iface=$(default_route_iface 2>/dev/null || true)
	if [ -n "$route_iface" ] && [ -e "/sys/class/net/$route_iface" ]; then
		printf '%s\n' "$route_iface"
		return 0
	fi
	all_wifi_ifaces | head -n 1
}

find_scan_wifi_iface() {
	client=$(find_client_wifi_iface 2>/dev/null || true)
	if [ -n "$SCAN_IFACE" ] && [ -e "/sys/class/net/$SCAN_IFACE" ] && [ "$SCAN_IFACE" != "$client" ]; then
		printf '%s\n' "$SCAN_IFACE"
		return 0
	fi
	for iface in $(all_wifi_ifaces); do
		[ "$iface" = "$client" ] && continue
		[ "$(iface_driver "$iface")" = "$SCAN_DRIVER" ] || continue
		printf '%s\n' "$iface"
		return 0
	done
	for iface in $(all_wifi_ifaces); do
		[ "$iface" = "$client" ] && continue
		printf '%s\n' "$iface"
		return 0
	done
	[ -n "$client" ] && printf '%s\n' "$client"
}

ensure_client_wifi() {
	modprobe r8723bs rtw_power_mgnt=0 rtw_ips_mode=0 2>/dev/null || modprobe r8723bs 2>/dev/null || true
	rfkill unblock wifi 2>/dev/null || true
	i=0
	while [ "$i" -lt 15 ]; do
		iface=$(find_client_wifi_iface 2>/dev/null || true)
		[ -n "${iface:-}" ] && break
		i=$((i + 1))
		sleep 1
	done
	[ -n "${iface:-}" ] || {
		echo "No WiFi interface found" >&2
		return 1
	}
	ip link set "$iface" up 2>/dev/null || ifconfig "$iface" up 2>/dev/null || true
	printf '%s\n' "$iface"
}

ensure_scan_wifi() {
	modprobe 8812au 2>/dev/null || true
	rfkill unblock wifi 2>/dev/null || true
	i=0
	while [ "$i" -lt 10 ]; do
		iface=$(find_scan_wifi_iface 2>/dev/null || true)
		[ -n "${iface:-}" ] && break
		i=$((i + 1))
		sleep 1
	done
	[ -n "${iface:-}" ] || {
		echo "No external scan WiFi interface found" >&2
		return 1
	}
	ip link set "$iface" up 2>/dev/null || ifconfig "$iface" up 2>/dev/null || true
	printf '%s\n' "$iface"
}

scan_with_iw() {
	iface=$1
	tmp=/tmp/x-chip-iw-scan.$$
	if ! iw_scan "$iface" >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	sed -n 's/^[[:space:]]*SSID: //p' "$tmp" | sed '/^$/d' | sort -u
	rm -f "$tmp"
}

iw_scan() {
	iface=$1
	if [ "$(id -u)" = 0 ]; then
		iw dev "$iface" scan
	elif command -v sudo >/dev/null 2>&1; then
		sudo iw dev "$iface" scan
	else
		iw dev "$iface" scan
	fi
}

scan_with_iw_verbose() {
	iface=$1
	iw_scan "$iface" 2>/dev/null | awk '
		/^BSS / { ssid = ""; signal = ""; freq = ""; next }
		/^[[:space:]]*freq:/ { freq = $2 }
		/^[[:space:]]*signal:/ { signal = $2 " " $3 }
		/^[[:space:]]*SSID:/ {
			sub(/^[[:space:]]*SSID: /, "")
			ssid = $0
			if (ssid != "") printf "%-28s %9s %s MHz\n", ssid, signal, freq
		}
	'
}

scan_with_iwlist() {
	iface=$1
	iwlist "$iface" scan 2>/dev/null | sed -n 's/.*ESSID:"\(.*\)".*/\1/p' | sed '/^$/d' | sort -u
}

scan_networks() {
	iface=$1
	scan_with_iw "$iface" || scan_with_iwlist "$iface" || true
}

scan_report() {
	iface=${1:-}
	if [ -z "$iface" ]; then
		if ! iface=$(ensure_scan_wifi); then
			return 1
		fi
	fi
	echo "Scan interface: $iface ($(iface_driver "$iface"))"
	echo
	if command -v iw >/dev/null 2>&1; then
		scan_with_iw_verbose "$iface" || true
	else
		scan_with_iwlist "$iface" || true
	fi
}

escape_conf() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_root_file() {
	tmp=$1
	dest=$2
	if [ "$(id -u)" = 0 ]; then
		install -m600 "$tmp" "$dest"
	elif command -v sudo >/dev/null 2>&1; then
		sudo install -m600 "$tmp" "$dest"
	else
		echo "Need root to write $dest" >&2
		return 1
	fi
}

save_network() {
	ssid=$1
	psk=$2
	tmp=/tmp/x-chip-wpa.$$
	old_umask=$(umask)
	umask 077
	ssid_escaped=$(escape_conf "$ssid")
	{
		echo "ctrl_interface=/var/run/wpa_supplicant"
		echo "update_config=1"
		echo "country=$COUNTRY"
		echo
		echo "network={"
		echo "	ssid=\"$ssid_escaped\""
		if [ -n "$psk" ]; then
			psk_escaped=$(escape_conf "$psk")
			echo "	psk=\"$psk_escaped\""
			echo "	key_mgmt=WPA-PSK"
		else
			echo "	key_mgmt=NONE"
		fi
		echo "}"
	} >"$tmp"
	umask "$old_umask"
	write_root_file "$tmp" "$CONF"
	rm -f "$tmp"
	if command -v filetool.sh >/dev/null 2>&1; then
		filetool.sh -b >/tmp/x-chip-wifi-filetool.log 2>&1 || true
	fi
}

restart_wifi() {
	iface=$1
	if command -v wpa_cli >/dev/null 2>&1; then
		wpa_cli -i "$iface" terminate >/dev/null 2>&1 || true
	else
		killall wpa_supplicant >/dev/null 2>&1 || true
	fi
	sleep 1
	wpa_supplicant -B -i "$iface" -c "$CONF" >/var/log/wpa_supplicant.log 2>&1 || {
		echo "wpa_supplicant failed; see /var/log/wpa_supplicant.log"
		return 1
	}
	if command -v dhcpcd >/dev/null 2>&1; then
		dhcpcd -q -t 20 "$iface" >/var/log/dhcpcd-"$iface".log 2>&1 || true
	elif command -v udhcpc >/dev/null 2>&1; then
		udhcpc -i "$iface" -x "hostname:$HOSTNAME_VALUE" -b >/var/log/udhcpc-"$iface".log 2>&1 || true
	fi
}

show_status() {
	iface=$(find_client_wifi_iface 2>/dev/null || true)
	echo "Client interface: ${iface:-none}"
	if [ -n "${iface:-}" ]; then
		echo "Driver: $(iface_driver "$iface")"
		if command -v ip >/dev/null 2>&1; then
			ip addr show "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet /IPv4: /p' | head -n 1 || true
		elif command -v ifconfig >/dev/null 2>&1; then
			ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet addr:\([^ ]*\).*/IPv4: \1/p; s/.*inet \([0-9.][0-9.]*\).*/IPv4: \1/p' | head -n 1 || true
		fi
		iw dev "$iface" link 2>/dev/null || true
	fi
	[ -r "$CONF" ] && sed -n 's/^[[:space:]]*ssid="\([^"]*\)".*/Saved SSID: \1/p' "$CONF" | head -n 1
}

show_interfaces() {
	client=$(find_client_wifi_iface 2>/dev/null || true)
	scan=$(find_scan_wifi_iface 2>/dev/null || true)
	route_iface=$(default_route_iface 2>/dev/null || true)
	echo "WiFi Roles"
	echo "=========="
	echo "Client driver: $CLIENT_DRIVER"
	echo "Scan driver:   $SCAN_DRIVER"
	echo "Client iface:  ${client:-none}"
	echo "Scan iface:    ${scan:-none}"
	echo "Default route: ${route_iface:-none}"
	echo
	for iface in $(all_wifi_ifaces); do
		role=spare
		[ "$iface" = "$client" ] && role=client
		[ "$iface" = "$scan" ] && [ "$iface" != "$client" ] && role=scan
		echo "$iface  role=$role  driver=$(iface_driver "$iface")"
		if command -v ip >/dev/null 2>&1; then
			ip addr show "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet /  IPv4: /p' | head -n 1 || true
		else
			ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet addr:\([^ ]*\).*/  IPv4: \1/p; s/.*inet \([0-9.][0-9.]*\).*/  IPv4: \1/p' | head -n 1 || true
		fi
		iw dev "$iface" link 2>/dev/null | sed 's/^/  /' || true
		echo
	done
}

connect_menu() {
	iface=$(ensure_client_wifi) || {
		echo "Press enter to exit."
		read _ || true
		exit 1
	}
	tmp=/tmp/x-chip-wifi-scan.$$
	scan_networks "$iface" >"$tmp"
	if [ ! -s "$tmp" ]; then
		echo "No networks found."
		echo "Press enter to rescan or type an SSID manually."
		read ssid || ssid=
	else
		echo "Networks:"
		awk '{ printf "%2d) %s\n", NR, $0 }' "$tmp"
		echo
		echo "Type number, r to rescan, m for manual SSID, q to quit."
		printf '> '
		read choice || choice=q
		case "$choice" in
			q|Q) rm -f "$tmp"; exit 0 ;;
			r|R) rm -f "$tmp"; exec "$0" ;;
			m|M)
				printf 'SSID: '
				read ssid || ssid=
				;;
			*[!0-9]*|'')
				echo "Invalid selection"
				rm -f "$tmp"
				sleep 1
				exec "$0"
				;;
			*)
				ssid=$(sed -n "${choice}p" "$tmp")
				;;
		esac
	fi
	rm -f "$tmp"
	[ -n "${ssid:-}" ] || exit 0
	printf 'Password for "%s" (empty for open network): ' "$ssid"
	stty -echo 2>/dev/null || true
	read psk || psk=
	stty echo 2>/dev/null || true
	echo
	save_network "$ssid" "$psk"
	echo "Saved $ssid"
	restart_wifi "$iface" || true
	echo
	show_status
	echo
	echo "Press enter to close."
	read _ || true
}

case "${1:-menu}" in
	menu) connect_menu ;;
	status) show_status ;;
	interfaces) show_interfaces ;;
	scan|scan-external)
		iface=$(ensure_scan_wifi)
		scan_report "$iface"
		;;
	scan-client)
		iface=$(ensure_client_wifi)
		scan_report "$iface"
		;;
	restart)
		iface=$(ensure_client_wifi)
		restart_wifi "$iface"
		;;
	client-iface) find_client_wifi_iface ;;
	scan-iface) find_scan_wifi_iface ;;
	*) echo "Usage: x-chip-wifi-menu [menu|status|interfaces|scan|scan-external|scan-client|restart|client-iface|scan-iface]" >&2; exit 2 ;;
esac
EOF
}

install_media_tools() {
    need_root install -d "$RFS/usr/local/bin"
    need_root install -d "$RFS/home/$SSH_USER/Pictures" "$RFS/home/$SSH_USER/Videos" \
        "$RFS/home/$SSH_USER/Music" "$RFS/home/$SSH_USER/Downloads" \
        "$RFS/home/$SSH_USER/Games/GameBoy"
    need_root install -m 0644 config/sample-media/Pictures/red-hood-field.jpeg \
        "$RFS/home/$SSH_USER/Pictures/red-hood-field.jpeg"
    need_root install -m 0644 config/sample-media/Videos/pocket-video-demo.mp4 \
        "$RFS/home/$SSH_USER/Videos/pocket-video-demo.mp4"
    need_root install -m 0644 config/sample-media/Videos/night-lamp-dream.mp4 \
        "$RFS/home/$SSH_USER/Videos/night-lamp-dream.mp4"
    need_root install -m 0644 config/sample-media/Music/dreamscape-sample.mp3 \
        "$RFS/home/$SSH_USER/Music/dreamscape-sample.mp3"
    if [ "${INCLUDE_PRIVATE_ROMS:-0}" = 1 ]; then
        if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
            echo "ERROR: INCLUDE_PRIVATE_ROMS=1 is not allowed with PUBLIC_IMAGE=1" >&2
            exit 1
        fi
        local private_roms_dir
        private_roms_dir=$(resolve_path "${PRIVATE_ROMS_DIR:-dist/private-roms/GameBoy}")
        [ -d "$private_roms_dir" ] || {
            echo "ERROR: private ROM directory does not exist: $private_roms_dir" >&2
            exit 1
        }
        local copied_roms=0 rom
        while IFS= read -r rom; do
            need_root install -m 0644 "$rom" "$RFS/home/$SSH_USER/Games/GameBoy/${rom##*/}"
            copied_roms=$((copied_roms + 1))
        done < <(find "$private_roms_dir" -maxdepth 1 -type f \( \
            -iname '*.gb' -o -iname '*.gbc' -o -iname '*.gba' \) | sort)
        [ "$copied_roms" -gt 0 ] || {
            echo "ERROR: INCLUDE_PRIVATE_ROMS=1 but no .gb/.gbc/.gba files were found in $private_roms_dir" >&2
            exit 1
        }
        echo ">> copied $copied_roms private Game Boy ROM(s)"
    fi
    need_root chown "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER/Pictures" "$RFS/home/$SSH_USER/Videos" \
        "$RFS/home/$SSH_USER/Music" "$RFS/home/$SSH_USER/Downloads" \
        "$RFS/home/$SSH_USER/Games" "$RFS/home/$SSH_USER/Games/GameBoy"
    need_root chown "$SSH_UID:$SSH_GID" \
        "$RFS/home/$SSH_USER/Pictures/red-hood-field.jpeg" \
        "$RFS/home/$SSH_USER/Videos/pocket-video-demo.mp4" \
        "$RFS/home/$SSH_USER/Videos/night-lamp-dream.mp4" \
        "$RFS/home/$SSH_USER/Music/dreamscape-sample.mp3"
    if [ "${INCLUDE_PRIVATE_ROMS:-0}" = 1 ]; then
        need_root chown "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER/Games/GameBoy"/* 2>/dev/null || true
    fi
    install_text 0755 "$RFS/usr/local/bin/x-chip-media-on" <<'EOF'
#!/bin/sh
set -eu

MEDIA_LIST=/tce/media.lst
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"
LOCK_DIR=/tmp/x-chip-media-on.lock

scrub_kernel_placeholder_deps() {
	for depfile in /tce/optional/*.tcz.dep; do
		[ -f "$depfile" ] || continue
		grep -q KERNEL "$depfile" 2>/dev/null || continue
		tmp="/tmp/${depfile##*/}.clean"
		grep -v KERNEL "$depfile" >"$tmp" || true
		install -m644 "$tmp" "$depfile"
		rm -f "$tmp"
	done
}

extension_ready() {
	ext="$1"
	app="${ext%.tcz}"
	case "$app" in
		ffmpeg)
			command -v ffplay >/dev/null 2>&1
			;;
		mpg123)
			command -v mpg123 >/dev/null 2>&1
			;;
		*)
			[ -e "/usr/local/tce.installed/$app" ]
			;;
	esac
}

load_tcz_one() {
	ext="$1"
	case "$ext" in
		''|\#*) return 0 ;;
	esac
	case "$ext" in
		*.tcz) ;;
		*) ext="$ext.tcz" ;;
	esac
	extension_ready "$ext" && return 0
	scrub_kernel_placeholder_deps
	if [ -f "/tce/optional/$ext" ]; then
		target="/tce/optional/$ext"
	else
		target="$ext"
	fi
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

commands_ready() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || return 1
	done
	return 0
}

require_commands() {
	missing=0
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "$cmd unavailable" >&2
			missing=1
		fi
	done
	[ "$missing" = 0 ] || exit 1
}

load_media_list() {
	[ -f "$MEDIA_LIST" ] || {
		echo "missing $MEDIA_LIST" >&2
		exit 1
	}
	while IFS= read -r ext; do
		ext=${ext%%#*}
		set -- $ext
		ext=${1:-}
		load_tcz_one "$ext"
	done < "$MEDIA_LIST"
}

acquire_lock() {
	waited=0
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		waited=$((waited + 1))
		[ "$waited" -lt 90 ] || {
			echo "media loader is busy" >&2
			exit 1
		}
		sleep 1
	done
	trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

command -v tce-load >/dev/null 2>&1 || {
	echo "missing tce-load" >&2
	exit 1
}

case "${1:-all}" in
	all|media)
		commands_ready ffplay mpg123 && { echo "media ready"; exit 0; }
		acquire_lock
		commands_ready ffplay mpg123 && { echo "media ready"; exit 0; }
		load_media_list
		require_commands ffplay mpg123
		;;
	ffmpeg|ffplay|video)
		commands_ready ffplay && { echo "media ready"; exit 0; }
		acquire_lock
		commands_ready ffplay && { echo "media ready"; exit 0; }
		load_tcz_one ffmpeg.tcz
		require_commands ffplay
		;;
	mpg123|music|audio)
		commands_ready mpg123 && { echo "media ready"; exit 0; }
		acquire_lock
		commands_ready mpg123 && { echo "media ready"; exit 0; }
		load_tcz_one mpg123.tcz
		require_commands mpg123
		;;
	*)
		echo "Usage: x-chip-media-on [all|ffmpeg|mpg123]" >&2
		exit 2
		;;
esac

echo "media ready"
EOF
}

install_xorg_desktop_tools() {
    need_root install -d "$RFS/usr/local/bin" \
        "$RFS/usr/local/etc/mc" \
        "$RFS/usr/local/share/applications" \
        "$RFS/usr/local/etc/X11/xorg.conf.d" \
        "$RFS/etc/X11/xorg.conf.d" \
        "$RFS/usr/local/share/x-chip/xorg" \
        "$RFS/usr/local/share/x-chip/xorg/wallpapers"

    install_text 0755 "$RFS/usr/local/bin/x-chip-startx" <<'EOF'
#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

XORG_LIST=/tce/xorg.lst
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"
LOG=/tmp/x-chip-startx.log
X_CHIP_WM="${X_CHIP_WM:-jwm}"
X_CHIP_VT="${X_CHIP_VT:-2}"

case "$X_CHIP_WM" in
	flwm|jwm) ;;
	*) X_CHIP_WM=jwm ;;
esac

scrub_kernel_placeholder_deps() {
	for depfile in /tce/optional/*.tcz.dep; do
		[ -f "$depfile" ] || continue
		grep -q KERNEL "$depfile" 2>/dev/null || continue
		tmp="/tmp/${depfile##*/}.clean"
		grep -v KERNEL "$depfile" >"$tmp" || true
		install -m644 "$tmp" "$depfile"
		rm -f "$tmp"
	done
}

extension_ready() {
	ext="$1"
	app="${ext%.tcz}"
	case "$app" in
		Xorg|xorg-server)
			command -v Xorg >/dev/null 2>&1 && \
				command -v xinput >/dev/null 2>&1 && \
				[ -x /usr/local/lib/xorg/Xorg ]
			;;
		xf86-video-fbdev)
			[ -e /usr/local/lib/xorg/modules/drivers/fbdev_drv.so ]
			;;
		xf86-input-libinput)
			[ -e /usr/local/lib/xorg/modules/input/libinput_drv.so ]
			;;
		flwm|jwm|aterm|xrandr|xinput|dillo|leafpad|bc|gpicview|geany|pcmanfm|conky)
			command -v "$app" >/dev/null 2>&1
			;;
		libffi6)
			[ -e /usr/local/lib/libffi.so.6 ] || [ -e /usr/local/lib/libffi.so.6.0.4 ]
			;;
		libfm)
			[ -e /usr/local/lib/libfm.so ] || [ -e /usr/local/lib/libfm.so.4 ] || [ -e /usr/local/lib/libfm.so.4.1.2 ]
			;;
		gtk2)
			command -v gtk-query-immodules-2.0 >/dev/null 2>&1 && [ -d /usr/local/lib/gtk-2.0 ]
			;;
		gtk3)
			command -v gtk-query-immodules-3.0 >/dev/null 2>&1 && [ -d /usr/local/share/glib-2.0/schemas ]
			;;
		gdk-pixbuf)
			command -v gdk-pixbuf-query-loaders >/dev/null 2>&1 && [ -d /usr/local/lib/gdk-pixbuf-2.0 ]
			;;
		adwaita-icon-theme)
			[ -d /usr/local/share/icons/Adwaita ]
			;;
		hicolor-icon-theme)
			[ -d /usr/local/share/icons/hicolor ]
			;;
		*)
			[ -e "/usr/local/tce.installed/$app" ]
			;;
	esac
}

load_tcz_one() {
	ext="$1"
	case "$ext" in
		''|\#*) return 0 ;;
	esac
	case "$ext" in
		*.tcz) ;;
		*) ext="$ext.tcz" ;;
	esac
	extension_ready "$ext" && return 0
	scrub_kernel_placeholder_deps
	if [ -f "/tce/optional/$ext" ]; then
		target="/tce/optional/$ext"
	else
		target="$ext"
	fi
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

load_xorg_stack() {
	[ -f "$XORG_LIST" ] || {
		echo "missing $XORG_LIST" >&2
		exit 1
	}
	command -v tce-load >/dev/null 2>&1 || {
		echo "missing tce-load" >&2
		exit 1
	}
	while IFS= read -r ext; do
		ext=${ext%%#*}
		set -- $ext
		ext=${1:-}
		load_tcz_one "$ext"
	done < "$XORG_LIST"
}

prune_conflicting_xorg_defaults() {
	for conf in \
		/usr/local/share/X11/xorg.conf.d/20-noglamor.conf \
		/etc/X11/xorg.conf.d/20-noglamor.conf; do
		[ -e "$conf" ] || continue
		if [ "$(id -u)" = 0 ]; then
			rm -f "$conf" 2>/dev/null || true
		elif command -v sudo >/dev/null 2>&1; then
			sudo rm -f "$conf" 2>/dev/null || true
		fi
	done
}

user_home() {
	awk -F: -v user="$TC_USER" '$1 == user { print $6; found = 1 } END { exit found ? 0 : 1 }' /etc/passwd 2>/dev/null || \
		printf '/home/%s\n' "$TC_USER"
}

install_user_desktop_config() {
	home="$(user_home)"
	mkdir -p "$home"
	cp /usr/local/share/x-chip/xorg/jwmrc "$home/.jwmrc"
	mkdir -p "$home/.config/geany" "$home/.config/leafpad" \
		"$home/.config/pcmanfm/default" "$home/.config/gtk-3.0" "$home/.config/mc" \
		"$home/.local/share/applications" "$home/.dillo"
	cp /usr/local/share/x-chip/xorg/geany.conf "$home/.config/geany/geany.conf"
	cp /usr/local/share/x-chip/xorg/leafpadrc "$home/.config/leafpad/leafpadrc"
	cp /usr/local/share/x-chip/xorg/pcmanfm.conf "$home/.config/pcmanfm/default/pcmanfm.conf"
	cp /usr/local/share/x-chip/xorg/mc.ini "$home/.config/mc/ini"
	cp /usr/local/share/applications/mimeapps.list "$home/.config/mimeapps.list"
	cp /usr/local/share/applications/mimeapps.list "$home/.local/share/applications/mimeapps.list"
	cp /usr/local/share/applications/x-chip-*.desktop "$home/.local/share/applications/" 2>/dev/null || true
	cp /usr/local/share/x-chip/xorg/dillorc "$home/.dillo/dillorc"
	cp /usr/local/share/x-chip/xorg/gtkrc-2.0 "$home/.gtkrc-2.0"
	cp /usr/local/share/x-chip/xorg/Xdefaults "$home/.Xdefaults"
	cp /usr/local/share/x-chip/xorg/gtk3-settings.ini "$home/.config/gtk-3.0/settings.ini"
	if id "$TC_USER" >/dev/null 2>&1; then
		chown -R "$TC_USER":"$TC_USER" "$home/.jwmrc" "$home/.config" "$home/.local" "$home/.dillo" "$home/.gtkrc-2.0" "$home/.Xdefaults" 2>/dev/null || true
	fi
}

refresh_graphical_caches() {
	[ -x /usr/local/bin/x-chip-gtk-cache ] || return 0
	/usr/local/bin/x-chip-gtk-cache quick >>/tmp/x-chip-gtk-cache.log 2>&1 || true
}

wait_for_x_ready() {
	i=0
	while [ "$i" -lt 45 ]; do
		DISPLAY=:0 xinput list >/dev/null 2>&1 && return 0
		DISPLAY=:0 xset q >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

start_x_session() {
	echo "Starting Xorg desktop session on VT$X_CHIP_VT; log: $LOG"
	if [ -S /tmp/.X11-unix/X0 ]; then
		if ! pidof Xorg >/dev/null 2>&1; then
			rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock 2>/dev/null || true
		else
			wait_for_x_ready || true
			DISPLAY=:0 x-chip-x-apply-calibration >/tmp/x-chip-x-calibration.log 2>&1 || true
			DISPLAY=:0 x-chip-x-keymap >/tmp/x-chip-x-keymap.log 2>&1 || true
			if pidof "$X_CHIP_WM" >/dev/null 2>&1; then
				[ "$X_CHIP_WM" = jwm ] && DISPLAY=:0 jwm -restart >/tmp/jwm-restart.log 2>&1 || true
			elif id "$TC_USER" >/dev/null 2>&1; then
				su - "$TC_USER" -c "DISPLAY=:0 X_CHIP_WM=$X_CHIP_WM /usr/local/bin/x-chip-xorg-session" >/tmp/x-chip-wm-recover.log 2>&1 &
			else
				DISPLAY=:0 X_CHIP_WM="$X_CHIP_WM" /usr/local/bin/x-chip-xorg-session >/tmp/x-chip-wm-recover.log 2>&1 &
			fi
			exit 0
		fi
	fi
	rm -f "$LOG" 2>/dev/null || sudo rm -f "$LOG" 2>/dev/null || true
	if [ "$(id -u)" = 0 ]; then
		env TC_USER="$TC_USER" X_CHIP_WM="$X_CHIP_WM" X_CHIP_VT="$X_CHIP_VT" \
			setsid openvt -c "$X_CHIP_VT" -- /usr/local/bin/x-chip-xorg-launch-vt >"$LOG" 2>&1 &
		sleep 2
		chvt "$X_CHIP_VT" >/dev/null 2>&1 || true
		exit 0
	fi
	sudo env TC_USER="$TC_USER" X_CHIP_WM="$X_CHIP_WM" X_CHIP_VT="$X_CHIP_VT" \
		setsid openvt -c "$X_CHIP_VT" -- /usr/local/bin/x-chip-xorg-launch-vt >"$LOG" 2>&1 &
	sleep 2
	sudo chvt "$X_CHIP_VT" >/dev/null 2>&1 || true
}

load_xorg_stack
prune_conflicting_xorg_defaults
refresh_graphical_caches
install_user_desktop_config
start_x_session
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-desktop-start" <<'EOF'
#!/bin/sh
set -eu

CONFIG=${X_CHIP_DESKTOP_CONFIG:-/usr/local/etc/x-chip/desktop.conf}
AUTOSTART=1
WM=jwm
VT=2

if [ -r "$CONFIG" ]; then
	# shellcheck disable=SC1090
	. "$CONFIG"
	AUTOSTART=${X_CHIP_DESKTOP_AUTOSTART:-$AUTOSTART}
	WM=${X_CHIP_DESKTOP_WM:-$WM}
	VT=${X_CHIP_DESKTOP_VT:-$VT}
fi

case "$WM" in
	jwm|flwm) ;;
	*) WM=jwm ;;
esac
case "$VT" in
	''|*[!0-9]*) VT=2 ;;
esac

if [ "${1:-}" = "--boot" ]; then
	case "$AUTOSTART" in
		1|yes|true|on) ;;
		*) echo "Desktop autostart disabled in $CONFIG"; exit 0 ;;
	esac
fi

exec env X_CHIP_WM="$WM" X_CHIP_VT="$VT" /usr/local/bin/x-chip-startx
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-gtk-cache" <<'EOF'
#!/bin/sh
set -u

MODE=${1:-quick}
LOG=${X_CHIP_GTK_CACHE_LOG:-/tmp/x-chip-gtk-cache.log}
LOCK=/tmp/x-chip-gtk-cache.lock

if ! mkdir "$LOCK" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

run_if_present() {
	cmd=$1
	shift
	command -v "$cmd" >/dev/null 2>&1 || return 0
	"$cmd" "$@" >>"$LOG" 2>&1 || true
}

refresh_icon_theme() {
	dir=$1
	[ -d "$dir" ] || return 0
	cache="$dir/icon-theme.cache"
	[ "$MODE" = full ] || [ ! -s "$cache" ] || return 0
	run_if_present gtk-update-icon-cache -q -f -t "$dir"
}

refresh_gdk_pixbuf_loaders() {
	target=/usr/local/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
	[ "$MODE" = full ] || [ ! -s "$target" ] || return 0
	command -v gdk-pixbuf-query-loaders >/dev/null 2>&1 || return 0
	tmp="$target.$$"
	if gdk-pixbuf-query-loaders >"$tmp" 2>>"$LOG"; then
		mv "$tmp" "$target" 2>>"$LOG" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

refresh_file_if_missing() {
	target=$1
	shift
	[ "$MODE" = full ] || [ ! -s "$target" ] || return 0
	run_if_present "$@"
}

mkdir -p /usr/local/lib/gdk-pixbuf-2.0/2.10.0 \
	/usr/local/share/glib-2.0/schemas \
	/usr/local/share/applications \
	/usr/local/share/mime 2>/dev/null || true

refresh_gdk_pixbuf_loaders
refresh_file_if_missing /usr/local/share/mime/mime.cache \
	update-mime-database /usr/local/share/mime
refresh_file_if_missing /usr/local/share/glib-2.0/schemas/gschemas.compiled \
	glib-compile-schemas /usr/local/share/glib-2.0/schemas

refresh_icon_theme /usr/local/share/icons/x-chip
refresh_icon_theme /usr/local/share/icons/Adwaita
refresh_icon_theme /usr/local/share/icons/hicolor

if [ "$MODE" = full ]; then
	run_if_present gtk-query-immodules-2.0 --update-cache
	run_if_present gtk-query-immodules-3.0 --update-cache
	run_if_present update-desktop-database /usr/local/share/applications
	run_if_present fc-cache -sf
fi
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-close-app" <<'EOF'
#!/bin/sh
set -eu

close_one() {
	name=$1
	pkill "$name" 2>/dev/null || true
	sleep 1
	pkill -9 "$name" 2>/dev/null || true
}

case "${1:-all}" in
	files|pcmanfm) close_one pcmanfm ;;
	web|dillo) close_one dillo ;;
	code|geany) close_one geany ;;
	edit|leafpad) close_one leafpad ;;
	image|gpicview) close_one gpicview ;;
	video|ffplay) close_one ffplay ;;
	music|mpg123|sunvox|virtual-ans|pixitracker|pixitracker-1bit|pixilang)
		close_one mpg123
		close_one sunvox
		close_one sunvox-lofi
		close_one pixilang
		;;
	all)
		for app in pcmanfm dillo geany leafpad gpicview ffplay mpg123 sunvox sunvox-lofi pixilang; do
			close_one "$app"
		done
		;;
	*) echo "Usage: x-chip-close-app [all|files|web|code|edit|image|video|music|sunvox|virtual-ans|pixitracker|pixitracker-1bit|pixilang]" >&2; exit 2 ;;
esac

DISPLAY=${DISPLAY:-:0} jwm -restart 2>/dev/null || true
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-close-game" <<'EOF'
#!/bin/sh
set -eu

close_one() {
	name=$1
	pkill "$name" 2>/dev/null || true
}

force_one() {
	name=$1
	pkill -9 "$name" 2>/dev/null || true
}

for app in tic80 mgba-sdl1 mgba chocolate-doom pico8 goattracker sunvox sunvox-lofi pixilang; do
	close_one "$app"
done
sleep 1
for app in tic80 mgba-sdl1 mgba chocolate-doom pico8 goattracker sunvox sunvox-lofi pixilang; do
	force_one "$app"
done

DISPLAY=${DISPLAY:-:0} jwm -restart 2>/dev/null || true
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-game-launch" <<'EOF'
#!/bin/sh
set -eu

[ "$#" -gt 0 ] || {
	echo "Usage: x-chip-game-launch COMMAND [ARGS...]" >&2
	exit 2
}

cmd=$1
shift
case "$cmd" in
	x-chip-tic80|x-chip-mgba|x-chip-doom|x-chip-pico8|x-chip-goattracker) ;;
	*) echo "Refusing to launch non-game command: $cmd" >&2; exit 2 ;;
esac

DISPLAY=${DISPLAY:-:0}
HOME=${HOME:-/home/chip}
LOG=${X_CHIP_GAME_LAUNCH_LOG:-/tmp/x-chip-game-launch.log}

case "$cmd" in
	x-chip-tic80) pidof tic80 >/dev/null 2>&1 && exit 0 ;;
	x-chip-mgba) pidof mgba-sdl1 >/dev/null 2>&1 || pidof mgba >/dev/null 2>&1 && exit 0 ;;
	x-chip-doom) pidof chocolate-doom >/dev/null 2>&1 && exit 0 ;;
	x-chip-pico8) pidof pico8 >/dev/null 2>&1 && exit 0 ;;
	x-chip-goattracker) pidof goattracker >/dev/null 2>&1 && exit 0 ;;
esac

(
	cd "$HOME" 2>/dev/null || cd /
	export DISPLAY HOME
	{
		echo
		echo "=== $(date 2>/dev/null || true) ==="
		echo "$cmd $*"
	} >>"$LOG"
	exec "$cmd" "$@" >>"$LOG" 2>&1
) &

exit 0
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-x-apply-calibration" <<'EOF'
#!/bin/sh
set -eu

MATRIX_FILE=${X_CHIP_TOUCH_MATRIX_FILE:-/usr/local/share/x-chip/xorg/touchscreen-calibration.matrix}
DEVICE=${X_CHIP_TOUCH_DEVICE:-1c25000.rtp}

[ -n "${DISPLAY:-}" ] || exit 0
[ -f "$MATRIX_FILE" ] || exit 0
command -v xinput >/dev/null 2>&1 || exit 0

matrix="$(sed -n 's/#.*//; /^[[:space:]]*$/d; p; q' "$MATRIX_FILE")"
[ -n "$matrix" ] || exit 0

if command -v timeout >/dev/null 2>&1; then
	timeout 5 xinput set-prop "$DEVICE" "libinput Calibration Matrix" $matrix 2>/dev/null || \
		timeout 5 xinput set-prop "$DEVICE" "Coordinate Transformation Matrix" $matrix 2>/dev/null || true
else
	xinput set-prop "$DEVICE" "libinput Calibration Matrix" $matrix 2>/dev/null || \
		xinput set-prop "$DEVICE" "Coordinate Transformation Matrix" $matrix 2>/dev/null || true
fi
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-touch-calibrate" <<'EOF'
#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DISPLAY=${DISPLAY:-:0}
DEVICE=${X_CHIP_TOUCH_DEVICE:-1c25000.rtp}
MATRIX_FILE=${X_CHIP_TOUCH_MATRIX_FILE:-/usr/local/share/x-chip/xorg/touchscreen-calibration.matrix}
LOG=${X_CHIP_TOUCH_CALIBRATION_LOG:-/tmp/x-chip-touch-calibrate.log}
WIDTH=${X_CHIP_SCREEN_WIDTH:-480}
HEIGHT=${X_CHIP_SCREEN_HEIGHT:-272}
MARGIN=${X_CHIP_CALIBRATION_MARGIN:-64}
RAW_RANGE=${X_CHIP_TOUCH_RAW_RANGE:-65535}
TAP_TIMEOUT=${X_CHIP_CALIBRATION_TAP_TIMEOUT:-90}
TAP_RETRIES=${X_CHIP_CALIBRATION_TAP_RETRIES:-3}
SAMPLES_PER_TARGET=${X_CHIP_CALIBRATION_SAMPLES:-3}
TARGET_COLS=${X_CHIP_CALIBRATION_TARGET_COLS:-9}
TARGET_ROWS=${X_CHIP_CALIBRATION_TARGET_ROWS:-4}
TARGET_PIXEL_WIDTH=${X_CHIP_CALIBRATION_TARGET_PIXEL_WIDTH:-96}
TARGET_PIXEL_HEIGHT=${X_CHIP_CALIBRATION_TARGET_PIXEL_HEIGHT:-62}
FBDEV=${X_CHIP_FRAMEBUFFER:-/dev/fb0}

export DISPLAY

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "missing command: $1" >&2
		exit 1
	}
}

wait_for_x_ready() {
	i=0
	while [ "$i" -lt 45 ]; do
		xinput list >/dev/null 2>&1 && return 0
		xset q >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

set_identity_matrix() {
	xinput set-prop "$DEVICE" "libinput Calibration Matrix" 1 0 0 0 1 0 0 0 1 2>/dev/null || \
		xinput set-prop "$DEVICE" "Coordinate Transformation Matrix" 1 0 0 0 1 0 0 0 1 2>/dev/null || true
}

fb_bpp() {
	cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || echo 32
}

fb_line_length() {
	cat /sys/class/graphics/fb0/stride 2>/dev/null || echo $((WIDTH * $(fb_bpp) / 8))
}

clamp_coord() {
	value="$1"
	max="$2"
	[ "$value" -lt 0 ] && value=0
	[ "$value" -gt "$max" ] && value=$max
	echo "$value"
}

write_white_pixel() {
	case "$(fb_bpp)" in
		32) printf '\377\377\377\377' ;;
		24) printf '\377\377\377' ;;
		16) printf '\377\377' ;;
		8) printf '\377' ;;
		*) printf '\377\377\377\377' ;;
	esac
}

make_white_line() {
	count="$1"
	out="$2"
	: >"$out"
	i=0
	while [ "$i" -lt "$count" ]; do
		write_white_pixel >>"$out"
		i=$((i + 1))
	done
}

fb_write_file() {
	file="$1"
	offset="$2"
	dd if="$file" of="$FBDEV" bs=1 seek="$offset" conv=notrunc 2>/dev/null || true
}

fb_hline() {
	x1="$(clamp_coord "$1" $((WIDTH - 1)))"
	x2="$(clamp_coord "$2" $((WIDTH - 1)))"
	y="$(clamp_coord "$3" $((HEIGHT - 1)))"
	[ "$x1" -gt "$x2" ] && { tmpx="$x1"; x1="$x2"; x2="$tmpx"; }
	bytes_per_pixel=$(( $(fb_bpp) / 8 ))
	line_length="$(fb_line_length)"
	count=$((x2 - x1 + 1))
	line_file="/tmp/x-chip-calibration-line.$$"
	make_white_line "$count" "$line_file"
	fb_write_file "$line_file" $((y * line_length + x1 * bytes_per_pixel))
	rm -f "$line_file"
}

fb_vline() {
	x="$(clamp_coord "$1" $((WIDTH - 1)))"
	y1="$(clamp_coord "$2" $((HEIGHT - 1)))"
	y2="$(clamp_coord "$3" $((HEIGHT - 1)))"
	[ "$y1" -gt "$y2" ] && { tmpy="$y1"; y1="$y2"; y2="$tmpy"; }
	bytes_per_pixel=$(( $(fb_bpp) / 8 ))
	line_length="$(fb_line_length)"
	pixel_file="/tmp/x-chip-calibration-pixel.$$"
	write_white_pixel >"$pixel_file"
	y="$y1"
	while [ "$y" -le "$y2" ]; do
		fb_write_file "$pixel_file" $((y * line_length + x * bytes_per_pixel))
		y=$((y + 1))
	done
	rm -f "$pixel_file"
}

draw_framebuffer_target() {
	target_x="$1"
	target_y="$2"
	radius=18
	inner=5
	fb_hline $((target_x - radius)) $((target_x - inner)) "$target_y"
	fb_hline $((target_x + inner)) $((target_x + radius)) "$target_y"
	fb_vline "$target_x" $((target_y - radius)) $((target_y - inner))
	fb_vline "$target_x" $((target_y + inner)) $((target_y + radius))
	fb_hline $((target_x - 3)) $((target_x + 3)) "$target_y"
	fb_vline "$target_x" $((target_y - 3)) $((target_y + 3))
}

draw_window_target() {
	label="$1"
	target_x="$2"
	target_y="$3"
	left=$((target_x - TARGET_PIXEL_WIDTH / 2))
	top=$((target_y - TARGET_PIXEL_HEIGHT / 2))
	max_left=$((WIDTH - TARGET_PIXEL_WIDTH))
	max_top=$((HEIGHT - TARGET_PIXEL_HEIGHT))
	[ "$max_left" -lt 0 ] && max_left=0
	[ "$max_top" -lt 0 ] && max_top=0
	[ "$left" -lt 0 ] && left=0
	[ "$top" -lt 0 ] && top=0
	[ "$left" -gt "$max_left" ] && left=$max_left
	[ "$top" -gt "$max_top" ] && top=$max_top
	kill "$target_pid" 2>/dev/null || true
	geom="${TARGET_COLS}x${TARGET_ROWS}+${left}+${top}"
	aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry "$geom" -title "$label" \
		-e sh -c 'printf "\n   X\n  TAP\n"; sleep "$1"' sh "$TAP_TIMEOUT" \
		>/tmp/x-chip-calibration-target.log 2>&1 &
	target_pid=$!
}

draw_target() {
	label="$1"
	target_x="$2"
	target_y="$3"
	clear_framebuffer
	draw_framebuffer_target "$target_x" "$target_y"
	sleep 1
}

clear_framebuffer() {
	[ -w "$FBDEV" ] || {
		echo "$FBDEV is not writable; cannot draw calibration target" >&2
		return 1
	}
	line_length="$(fb_line_length)"
	size=$((line_length * HEIGHT))
	dd if=/dev/zero of="$FBDEV" bs="$size" count=1 conv=notrunc 2>/dev/null || true
}

stop_desktop_windows() {
	pkill -x aterm 2>/dev/null || true
	sleep 1
}

start_desktop_windows() {
	if ! pgrep -x aterm >/dev/null 2>&1; then
		aterm >/tmp/aterm.log 2>&1 &
	fi
}

extract_point() {
	awk '
		/EVENT type 22/ { touch=1; x=""; next }
		touch && $1 == "0:" { x=$2; next }
		touch && x != "" && $1 == "1:" { print x, $2; exit }
	' "$1"
}

capture_tap() {
	label="$1"
	target_x="$2"
	target_y="$3"
	out="/tmp/x-chip-calibration-$label.out"
	rm -f "$out"
	draw_target "$label" "$target_x" "$target_y"
	echo "Tap $label on the PocketCHIP screen..." >&2
	xinput test-xi2 --root "$DEVICE" >"$out" 2>>"$LOG" &
	xinput_pid=$!
	start=$(date +%s 2>/dev/null || echo 0)
	while :; do
		point="$(extract_point "$out" || true)"
		if [ -n "$point" ]; then
			kill "$xinput_pid" 2>/dev/null || true
			wait "$xinput_pid" 2>/dev/null || true
			printf '%s %s %s %s\n' "$point" "$target_x" "$target_y" "$label"
			return 0
		fi
		if ! kill -0 "$xinput_pid" 2>/dev/null; then
			wait "$xinput_pid" 2>/dev/null || true
			point="$(extract_point "$out" || true)"
			[ -n "$point" ] && printf '%s %s %s %s\n' "$point" "$target_x" "$target_y" "$label"
			return 0
		fi
		now=$(date +%s 2>/dev/null || echo 0)
		if [ "$start" -gt 0 ] && [ "$now" -ge "$((start + TAP_TIMEOUT))" ]; then
			kill "$xinput_pid" 2>/dev/null || true
			wait "$xinput_pid" 2>/dev/null || true
			return 0
		fi
		sleep 1
	done
}

capture_required_tap() {
	label="$1"
	target_x="$2"
	target_y="$3"
	attempt=1
	while [ "$attempt" -le "$TAP_RETRIES" ]; do
		point="$(capture_tap "$label" "$target_x" "$target_y")"
		if [ -n "$point" ]; then
			echo "$point"
			return 0
		fi
		echo "No tap captured for $label, retry $attempt/$TAP_RETRIES." >&2
		attempt=$((attempt + 1))
	done
	echo "Calibration failed: no tap captured for $label." >&2
	return 1
}

capture_averaged_tap() {
	label="$1"
	target_x="$2"
	target_y="$3"
	samples="/tmp/x-chip-calibration-$label.samples"
	rm -f "$samples"
	sample=1
	while [ "$sample" -le "$SAMPLES_PER_TARGET" ]; do
		point="$(capture_required_tap "$label-$sample-of-$SAMPLES_PER_TARGET" "$target_x" "$target_y")" || return 1
		echo "$point" >>"$samples"
		sleep 1
		sample=$((sample + 1))
	done
	awk -v tx="$target_x" -v ty="$target_y" -v label="$label" '
		NF >= 2 { sx += $1; sy += $2; n++ }
		END {
			if (n < 1) exit 1
			printf "%.2f %.2f %s %s %s\n", sx / n, sy / n, tx, ty, label
		}
	' "$samples"
	awk -v label="$label" 'NF >= 2 { printf "sample %s raw=%s,%s\n", label, $1, $2 }' "$samples" >>"$LOG"
}

compute_matrix() {
	awk -v w="$WIDTH" -v h="$HEIGHT" -v r="$RAW_RANGE" '
		function abs(v) {
			return v < 0 ? -v : v
		}
		function det(a,b,c,d,e,f,g,h,i) {
			return a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
		}
		function coeff(b0,b1,b2,   Da,Db,Dc) {
			Da=det(b0,sxy,sx,b1,syy,sy,b2,sy,n)
			Db=det(sxx,b0,sx,sxy,b1,sy,sx,b2,n)
			Dc=det(sxx,sxy,b0,sxy,syy,b1,sx,sy,b2)
			printf "%.9f %.9f %.9f", Da/D, Db/D, Dc/D
		}
		NF >= 4 {
			x=$1/r
			y=$2/r
			tx=$3/w
			ty=$4/h
			n++
			sxx += x*x
			sxy += x*y
			sx += x
			syy += y*y
			sy += y
			bx0 += x*tx
			bx1 += y*tx
			bx2 += tx
			by0 += x*ty
			by1 += y*ty
			by2 += ty
		}
		END {
			if (n < 3) exit 2
			D=det(sxx,sxy,sx,sxy,syy,sy,sx,sy,n)
			if (abs(D) < 0.000000001) exit 2
			coeff(bx0, bx1, bx2)
			printf " "
			coeff(by0, by1, by2)
			printf " 0 0 1\n"
		}
	' "$1"
}

save_matrix() {
	matrix="$1"
	points_file="$2"
	tmp="/tmp/touchscreen-calibration.matrix.$$"
	{
		echo "# PocketCHIP sun4i touchscreen -> 480x272 landscape Xorg."
		echo "# Generated by x-chip-touch-calibrate."
		echo "# Format: raw_x raw_y target_x target_y label"
		awk 'NF >= 5 { printf "# point %s raw=%s,%s target=%s,%s\n", $5, $1, $2, $3, $4 }' "$points_file"
		echo "$matrix"
	} >"$tmp"
	if [ "$(id -u)" = 0 ]; then
		install -m644 "$tmp" "$MATRIX_FILE"
	else
		sudo install -m644 "$tmp" "$MATRIX_FILE"
	fi
	rm -f "$tmp"
}

print_fit_error() {
	matrix="$1"
	awk -v m="$matrix" -v w="$WIDTH" -v h="$HEIGHT" -v r="$RAW_RANGE" '
		BEGIN { split(m, p, " ") }
		NF >= 4 {
			x=$1/r
			y=$2/r
			px=(p[1]*x + p[2]*y + p[3]) * w
			py=(p[4]*x + p[5]*y + p[6]) * h
			dx=px - $3
			dy=py - $4
			e=sqrt(dx*dx + dy*dy)
			sum += e
			if (e > max) max=e
			n++
		}
		END {
			if (n > 0) printf "Fit error: mean %.1f px, max %.1f px over %d points\n", sum/n, max, n
		}
	' "$points"
}

need_cmd xinput
need_cmd xset
need_cmd dd
need_cmd pgrep
need_cmd pkill

wait_for_x_ready || {
	echo "X is not ready on DISPLAY=$DISPLAY" >&2
	exit 1
}

: >"$LOG"
xinput_pid=
success=0

cleanup_calibration() {
	[ -n "${xinput_pid:-}" ] && kill "$xinput_pid" 2>/dev/null || true
	clear_framebuffer >/dev/null 2>&1 || true
	if [ "$success" != 1 ]; then
		DISPLAY="$DISPLAY" x-chip-x-apply-calibration >>"$LOG" 2>&1 || true
	fi
	start_desktop_windows
}

trap cleanup_calibration EXIT
trap 'exit 130' INT TERM

stop_desktop_windows
set_identity_matrix
points=/tmp/x-chip-calibration-points.txt
rm -f "$points"
capture_averaged_tap top-left "$MARGIN" "$MARGIN" >>"$points" || exit 1
capture_averaged_tap top-right "$((WIDTH - MARGIN))" "$MARGIN" >>"$points" || exit 1
capture_averaged_tap center "$((WIDTH / 2))" "$((HEIGHT / 2))" >>"$points" || exit 1
capture_averaged_tap bottom-left "$MARGIN" "$((HEIGHT - MARGIN))" >>"$points" || exit 1
capture_averaged_tap bottom-right "$((WIDTH - MARGIN))" "$((HEIGHT - MARGIN))" >>"$points" || exit 1

if [ "$(wc -l <"$points")" -ne 5 ]; then
	echo "Calibration failed: expected 5 taps, got:" >&2
	cat "$points" >&2
	exit 1
fi

matrix="$(compute_matrix "$points")"
save_matrix "$matrix" "$points"
x-chip-x-apply-calibration >>"$LOG" 2>&1 || true
success=1

echo "Saved calibration matrix:"
echo "$matrix"
print_fit_error "$matrix"
echo "File: $MATRIX_FILE"
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/pocketchip.xmodmap" <<'EOF'
! PocketCHIP internal keyboard Fn layer for X11.
! The console map treats the physical Fn key as AltGr; X11 needs its own map.
remove mod1 = Alt_R Meta_R
keycode 108 = Mode_switch
add mod5 = Mode_switch
keycode 10 = 1 exclam F1 F1
keycode 11 = 2 at F2 F2
keycode 12 = 3 numbersign F3 F3
keycode 13 = 4 dollar F4 F4
keycode 14 = 5 percent F5 F5
keycode 15 = 6 asciicircum F6 F6
keycode 16 = 7 ampersand F7 F7
keycode 17 = 8 asterisk F8 F8
keycode 18 = 9 parenleft F9 F9
keycode 19 = 0 parenright F10 F10
keycode 82 = KP_Subtract underscore F11 F11
keycode 21 = equal plus F12 F12
keycode 29 = y Y braceleft braceleft
keycode 30 = u U braceright braceright
keycode 31 = i I bracketleft bracketleft
keycode 32 = o O bracketright bracketright
keycode 33 = p P bar bar
keycode 43 = h H less less
keycode 44 = j J greater greater
keycode 45 = k K apostrophe apostrophe
keycode 46 = l L quotedbl quotedbl
keycode 56 = b B grave grave
keycode 57 = n N asciitilde asciitilde
keycode 58 = m M colon colon
keycode 60 = period greater semicolon semicolon
keycode 61 = slash question backslash backslash
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-x-keymap" <<'EOF'
#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DISPLAY=${DISPLAY:-:0}

MAP=${X_CHIP_X_KEYMAP:-/usr/local/share/x-chip/xorg/pocketchip.xmodmap}
LOG=${X_CHIP_X_KEYMAP_LOG:-/tmp/x-chip-x-keymap.log}

[ -r "$MAP" ] || exit 0
command -v xmodmap >/dev/null 2>&1 || exit 0

xmodmap "$MAP" >"$LOG" 2>&1
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-xorg-session" <<'EOF'
#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DISPLAY=${DISPLAY:-:0}
X_CHIP_WM=${X_CHIP_WM:-jwm}

x-chip-x-apply-calibration >/tmp/x-chip-x-calibration.log 2>&1 || true
x-chip-x-keymap >/tmp/x-chip-x-keymap.log 2>&1 || true
xset -dpms s off 2>/dev/null || true
if [ -f "$HOME/.Xdefaults" ] && command -v xrdb >/dev/null 2>&1; then
	xrdb -merge "$HOME/.Xdefaults" >/tmp/xrdb.log 2>&1 || true
fi

if [ ! -f "$HOME/.jwmrc" ] && [ -f /usr/local/share/x-chip/xorg/jwmrc ]; then
	cp /usr/local/share/x-chip/xorg/jwmrc "$HOME/.jwmrc"
fi

case "$X_CHIP_WM" in
	flwm)
		exec flwm
		;;
	jwm|*)
		exec jwm
		;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-xorg-launch-vt" <<'EOF'
#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TC_USER=${TC_USER:-$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)}
X_CHIP_WM=${X_CHIP_WM:-jwm}
X_CHIP_VT=${X_CHIP_VT:-2}
XORG_CONFIG=${XORG_CONFIG:-/usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf}
XORG_LOG=/tmp/x-chip-xorg.log
XORG_SERVER_LOG=/tmp/Xorg.0.log

mkdir -p /tmp/.X11-unix /tmp/.ICE-unix
chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix 2>/dev/null || true
rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock
rm -f "$XORG_SERVER_LOG"

for fbblank in /sys/class/graphics/fb*/blank; do
	[ -w "$fbblank" ] && echo 0 > "$fbblank" 2>/dev/null || true
done
for backlight in /sys/class/backlight/*; do
	[ -e "$backlight" ] || continue
	[ -w "$backlight/bl_power" ] && echo 0 > "$backlight/bl_power" 2>/dev/null || true
done
x-chip-brightness apply >/tmp/x-chip-brightness.log 2>&1 || true

Xorg :0 "vt$X_CHIP_VT" -config "$XORG_CONFIG" -logfile "$XORG_SERVER_LOG" -nolisten tcp >"$XORG_LOG" 2>&1 &
xpid=$!
ready=0
for _ in $(seq 1 30); do
	if [ -S /tmp/.X11-unix/X0 ]; then
		ready=1
		break
	fi
	if ! kill -0 "$xpid" 2>/dev/null; then
		break
	fi
	sleep 1
done

for _ in $(seq 1 45); do
	DISPLAY=:0 xinput list >/dev/null 2>&1 && break
	DISPLAY=:0 xset q >/dev/null 2>&1 && break
	if ! kill -0 "$xpid" 2>/dev/null; then
		break
	fi
	sleep 1
done

if [ "$ready" != 1 ]; then
	cat "$XORG_LOG" >&2 || true
	kill "$xpid" 2>/dev/null || true
	exit 1
fi

if id "$TC_USER" >/dev/null 2>&1; then
	su - "$TC_USER" -c "DISPLAY=:0 X_CHIP_WM=$X_CHIP_WM /usr/local/bin/x-chip-xorg-session" &
else
	DISPLAY=:0 X_CHIP_WM="$X_CHIP_WM" /usr/local/bin/x-chip-xorg-session &
fi

wait "$xpid"
EOF

    touch_calibration_source=$(resolve_path "${TOUCH_CALIBRATION_SOURCE:-config/pocketchip-touchscreen-calibration.matrix}")
    touch_calibration_matrix=$(read_touch_calibration_matrix "$touch_calibration_source")

    install_text 0644 "$RFS/usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf" <<EOF
Section "ServerFlags"
	Option "AutoAddDevices" "true"
	Option "AutoBindGPU" "false"
	Option "BlankTime" "0"
	Option "StandbyTime" "0"
	Option "SuspendTime" "0"
	Option "OffTime" "0"
EndSection

Section "Device"
	Identifier "PocketCHIP fbdev"
	Driver "fbdev"
	Option "fbdev" "/dev/fb0"
EndSection

Section "Screen"
	Identifier "PocketCHIP Screen"
	Device "PocketCHIP fbdev"
EndSection

Section "InputClass"
	Identifier "PocketCHIP touchscreen calibration"
	MatchProduct "1c25000.rtp"
	Driver "libinput"
	Option "CalibrationMatrix" "$touch_calibration_matrix"
EndSection
EOF
    need_root cp "$RFS/usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf" \
        "$RFS/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf"

    need_root install -m 0644 "$touch_calibration_source" \
        "$RFS/usr/local/share/x-chip/xorg/touchscreen-calibration.matrix"
    need_root install -m 0644 config/wallpapers/pocket-core.png \
        "$RFS/usr/local/share/x-chip/xorg/wallpapers/pocket-core.png"
    need_root install -d "$RFS/usr/local/share/mc/skins"
    for skin in config/mc-skins/*.ini; do
        [ -f "$skin" ] || continue
        need_root install -m 0644 "$skin" "$RFS/usr/local/share/mc/skins/${skin##*/}"
    done
    if [ -f config/mc-skins/gray-orange-blue256.ini ]; then
        need_root install -m 0644 config/mc-skins/gray-orange-blue256.ini \
            "$RFS/usr/local/share/mc/skins/pocketclean256.ini"
    fi
    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/mc.ini" <<'EOF'
[Midnight-Commander]
skin=pocketclean256

[Layout]
command_prompt=0
keybar_visible=0
message_visible=0
xterm_title=0
free_space=0
EOF

    need_root install -d "$RFS/usr/local/share/x-chip/xorg/icons"
    for icon in config/xorg-icons/*.xpm; do
        [ -f "$icon" ] || continue
        need_root install -m0644 "$icon" "$RFS/usr/local/share/x-chip/xorg/icons/${icon##*/}"
    done
    local icon_theme_base="$RFS/usr/local/share/icons/x-chip"
    need_root install -d \
        "$icon_theme_base/16x16/actions" \
        "$icon_theme_base/16x16/apps" \
        "$icon_theme_base/16x16/categories" \
        "$icon_theme_base/16x16/devices" \
        "$icon_theme_base/16x16/mimetypes" \
        "$icon_theme_base/16x16/places" \
        "$icon_theme_base/16x16/status"
    install_text 0644 "$icon_theme_base/index.theme" <<'EOF'
[Icon Theme]
Name=X-CHIP
Comment=PocketCHIP 16px icon theme
Inherits=Adwaita,hicolor
Directories=16x16/actions,16x16/apps,16x16/categories,16x16/devices,16x16/mimetypes,16x16/places,16x16/status

[16x16/actions]
Size=16
Context=Actions
Type=Fixed

[16x16/apps]
Size=16
Context=Applications
Type=Fixed

[16x16/categories]
Size=16
Context=Categories
Type=Fixed

[16x16/devices]
Size=16
Context=Devices
Type=Fixed

[16x16/mimetypes]
Size=16
Context=MimeTypes
Type=Fixed

[16x16/places]
Size=16
Context=Places
Type=Fixed

[16x16/status]
Size=16
Context=Status
Type=Fixed
EOF
    while read -r source target; do
        [ -n "$source" ] || continue
        need_root install -m0644 "config/xorg-icons/$source.xpm" \
            "$icon_theme_base/16x16/$target.xpm"
    done <<'EOF'
back actions/go-previous
forward actions/go-next
up actions/go-up
home actions/go-home
refresh actions/view-refresh
close actions/process-stop
close actions/window-close
close actions/gtk-close
file actions/document-new
file actions/gtk-new
files actions/document-open
files actions/gtk-open
editor actions/document-save
editor actions/gtk-save
editor actions/document-save-as
file actions/edit-copy
file actions/gtk-copy
file actions/edit-cut
file actions/gtk-cut
file actions/edit-paste
file actions/gtk-paste
close actions/edit-delete
close actions/gtk-delete
back actions/edit-undo
back actions/gtk-undo
forward actions/edit-redo
forward actions/gtk-redo
refresh actions/edit-find
refresh actions/gtk-find
files actions/folder-new
apps actions/list-add
apps actions/gtk-add
close actions/list-remove
close actions/gtk-remove
back actions/gtk-go-back
forward actions/gtk-go-forward
up actions/gtk-go-up
home actions/gtk-home
refresh actions/gtk-refresh
close actions/gtk-stop
forward actions/go-jump
forward actions/gtk-jump-to
files actions/gtk-directory
file actions/gtk-file
pocket actions/gtk-harddisk
files apps/file-manager
files apps/pcmanfm
browser apps/dillo
editor apps/leafpad
code apps/geany
terminal apps/utilities-terminal
apps categories/applications-other
apps categories/applications-system
pocket devices/computer
pocket devices/drive-harddisk
pocket devices/drive-removable-media
pocket devices/media-flash
files places/folder
files places/inode-directory
home places/user-home
home places/folder-home
home places/user-desktop
files places/folder-documents
files places/folder-download
image places/folder-pictures
pocket places/folder-music
monitor places/folder-videos
pocket places/computer
network places/network-workgroup
pocket devices/drive-harddisk-usb
pocket devices/drive-removable-media-usb
file mimetypes/text-x-generic
file mimetypes/unknown
file status/image-missing
file status/gtk-missing-image
editor mimetypes/text-plain
code mimetypes/application-x-executable
terminal mimetypes/application-x-shellscript
terminal mimetypes/text-x-script
browser mimetypes/text-html
image mimetypes/image-x-generic
image mimetypes/image-png
pocket mimetypes/audio-x-generic
monitor mimetypes/video-x-generic
file mimetypes/application-pdf
brightness status/display-brightness
network status/network-wireless
close status/dialog-error
monitor status/dialog-information
pocket status/dialog-warning
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/jwmrc" <<'EOF'
<?xml version="1.0"?>
<JWM>
  <IconPath>/usr/local/share/x-chip/xorg/icons</IconPath>
  <DefaultIcon>pocket.xpm</DefaultIcon>
  <StartupCommand>x-chip-x-apply-calibration</StartupCommand>
  <StartupCommand>x-chip-desktop-stats restore</StartupCommand>
  <RestartCommand>x-chip-x-apply-calibration</RestartCommand>

  <RootMenu onroot="3">
    <Menu label="Apps" icon="apps.xpm">
      <Program label="Terminal" icon="terminal.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Terminal</Program>
      <Program label="Files" icon="files.xpm">pcmanfm</Program>
      <Program label="Browser" icon="browser.xpm">dillo -g 474x212+0+0</Program>
      <Program label="Editor" icon="editor.xpm">leafpad</Program>
      <Program label="Code" icon="code.xpm">geany -s -m -p -t</Program>
      <Program label="Calculator" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Calculator -e x-chip-calc</Program>
      <Program label="Images" icon="image.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Images -e x-chip-open-image</Program>
      <Program label="Video" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Video -e x-chip-video</Program>
      <Separator/>
      <Program label="Links" icon="browser.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Links -e links</Program>
      <Program label="Nano" icon="editor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Nano -e nano</Program>
      <Program label="Midnight Commander" icon="files.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Files -e x-chip-mc</Program>
    </Menu>
    <Menu label="Music" icon="pocket.xpm">
      <Program label="Music Player" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Music -e x-chip-music</Program>
      <Separator/>
      <Program label="SunVox" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title SunVox -e x-chip-term-hold x-chip-sunvox</Program>
      <Program label="PixiTracker" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title PixiTracker -e x-chip-term-hold x-chip-pixitracker</Program>
      <Program label="PixiTracker 1Bit" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Pixi1Bit -e x-chip-term-hold x-chip-pixitracker-1bit</Program>
      <Program label="Pixilang" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Pixilang -e x-chip-term-hold x-chip-pixilang</Program>
      <Program label="GoatTracker" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title GoatTracker -e x-chip-term-hold x-chip-goattracker</Program>
    </Menu>
    <Menu label="Games" icon="apps.xpm">
      <Program label="Game Launcher" icon="apps.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Games -e x-chip-games</Program>
      <Separator/>
      <Program label="Doom" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Doom -e x-chip-term-hold x-chip-doom run</Program>
      <Program label="Game Boy Launcher" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title GameBoy -e x-chip-mgba</Program>
      <Program label="Game Boy Status" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title mGBA -e x-chip-term-hold x-chip-mgba status</Program>
      <Program label="2048 GB" icon="pocket.xpm">x-chip-game-launch x-chip-mgba play 2048</Program>
      <Program label="uCity" icon="pocket.xpm">x-chip-game-launch x-chip-mgba play ucity</Program>
      <Program label="PICO-8" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title PICO-8 -e x-chip-pico8 menu</Program>
      <Program label="TIC-80" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 run</Program>
      <Program label="TIC-80 Manager" icon="apps.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title TIC-80 -e x-chip-tic80 menu</Program>
      <Program label="Install All TIC-80 Games" icon="network.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title TIC-80 -e x-chip-term-hold x-chip-tic80 install-all</Program>
      <Menu label="TIC-80 Games" icon="pocket.xpm">
        <Program label="8 Bit Panda" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play 8-bit-panda</Program>
        <Program label="Stele" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play stele</Program>
        <Program label="Balmung" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play balmung</Program>
        <Program label="Supernova" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play supernova</Program>
        <Program label="Turns of War" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play turns-of-war</Program>
        <Program label="Cauliflower Power" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play cauliflower-power</Program>
        <Program label="Minetic" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play minetic</Program>
        <Program label="Powder Game" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play powder-game</Program>
        <Program label="Secret Agents" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play secret-agents</Program>
        <Program label="Komet" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play komet</Program>
        <Program label="The Sky House" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play the-sky-house</Program>
        <Program label="TIC-Sweeper" icon="pocket.xpm">x-chip-game-launch x-chip-tic80 play tic-sweeper</Program>
      </Menu>
    </Menu>
    <Menu label="Network" icon="network.xpm">
      <Program label="WiFi Setup" icon="network.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title WiFi -e x-chip-term-hold x-chip-wifi-menu</Program>
      <Program label="WiFi Status" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title WiFi -e x-chip-term-hold x-chip-wifi-menu status</Program>
      <Program label="WiFi Interfaces" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title WiFi -e x-chip-term-hold x-chip-wifi-menu interfaces</Program>
      <Program label="External Scan" icon="network.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Scan -e x-chip-term-hold x-chip-wifi-menu scan-external</Program>
    </Menu>
    <Menu label="Brightness" icon="brightness.xpm">
      <Program label="Control" icon="brightness.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Brightness -e x-chip-brightness menu</Program>
      <Program label="Brighter" icon="brightness.xpm">x-chip-brightness up</Program>
      <Program label="Dim" icon="brightness.xpm">x-chip-brightness down</Program>
      <Program label="Restore Default" icon="brightness.xpm">x-chip-brightness set 6</Program>
    </Menu>
    <Menu label="Pocket" icon="pocket.xpm">
      <Program label="Status" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x15+0+0 -title Status -e x-chip-status</Program>
      <Menu label="Time" icon="pocket.xpm">
        <Program label="Status" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Time -e x-chip-term-hold x-chip-time status</Program>
        <Program label="Sync Internet Time" icon="network.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Time -e x-chip-term-hold x-chip-time sync</Program>
        <Program label="Set Date/Time" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Time -e x-chip-time set</Program>
      </Menu>
      <Menu label="Desktop Stats" icon="monitor.xpm">
        <Program label="On" icon="monitor.xpm">x-chip-desktop-stats on</Program>
        <Program label="Off" icon="close.xpm">x-chip-desktop-stats off</Program>
        <Program label="Status" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Stats -e x-chip-term-hold x-chip-desktop-stats status</Program>
      </Menu>
      <Program label="Audio Mixer" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Audio -e alsamixer</Program>
      <Program label="Power" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Power -e x-chip-term-hold x-chip-power-status</Program>
      <Program label="Keyboard" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Keyboard -e x-chip-term-hold x-chip-keyboard-status</Program>
      <Program label="Audio Status" icon="pocket.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Audio -e x-chip-term-hold x-chip-audio-status</Program>
      <Program label="Logs" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Logs -e x-chip-logs</Program>
    </Menu>
    <Menu label="Touch" icon="touch.xpm">
      <Program label="Apply Calibration" icon="touch.xpm">x-chip-x-apply-calibration</Program>
      <Program label="Calibrate" icon="touch.xpm">x-chip-touch-calibrate</Program>
    </Menu>
    <Menu label="Window" icon="window.xpm">
      <Program label="Monitor" icon="monitor.xpm">aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Monitor -e htop</Program>
      <Program label="Close Games" icon="close.xpm">x-chip-close-game</Program>
      <Program label="Close Apps" icon="close.xpm">x-chip-close-app all</Program>
      <Restart label="Restart UI" icon="window.xpm"/>
    </Menu>
  </RootMenu>

  <Tray x="0" y="-1" width="480" height="32" autohide="off">
    <TrayButton label="Menu" icon="menu.xpm" popup="Open menu">root:3</TrayButton>
    <Spacer width="4"/>
    <TrayButton label="Term" icon="terminal.xpm" popup="Terminal">exec:aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Terminal</TrayButton>
    <Spacer width="4"/>
    <TrayButton label="Files" icon="files.xpm" popup="Files">exec:pcmanfm</TrayButton>
    <Spacer width="6"/>
    <TrayButton label="Play" icon="pocket.xpm" popup="Games">exec:aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -geometry 58x14+0+0 -title Games -e x-chip-games</TrayButton>
    <Spacer width="6"/>
    <TaskList maxwidth="160"/>
    <Clock format="%H:%M"/>
  </Tray>

  <WindowStyle decorations="motif">
    <Font>Luxi Sans-9</Font>
    <Width>2</Width>
    <Height>18</Height>
    <Corner>0</Corner>
    <Foreground>#EAF2EF</Foreground>
    <Background>#223331</Background>
    <Outline>#6A7A75</Outline>
    <Active>
      <Foreground>#0F1716</Foreground>
      <Background>#1F7A66</Background>
    </Active>
  </WindowStyle>

  <TrayStyle decorations="motif">
    <Font>Luxi Sans-9</Font>
    <Background>#0F1716</Background>
    <Foreground>#EAF2EF</Foreground>
  </TrayStyle>

  <TaskListStyle list="all" group="true">
    <Font>Luxi Sans-9</Font>
    <Foreground>#EAF2EF</Foreground>
    <Background>#223331</Background>
    <Active>
      <Foreground>#0F1716</Foreground>
      <Background>#1F7A66</Background>
    </Active>
  </TaskListStyle>

  <MenuStyle decorations="motif">
    <Font>Luxi Sans-9</Font>
    <Foreground>#EAF2EF</Foreground>
    <Background>#0F1716</Background>
    <Active>
      <Foreground>#0F1716</Foreground>
      <Background>#1F7A66</Background>
    </Active>
  </MenuStyle>

  <PopupStyle>
    <Font>Luxi Sans-9</Font>
    <Foreground>#EAF2EF</Foreground>
    <Background>#223331</Background>
  </PopupStyle>

  <Desktops width="1" height="1">
    <Background type="image">/usr/local/share/x-chip/xorg/wallpapers/pocket-core.png</Background>
  </Desktops>

  <FocusModel>click</FocusModel>
  <Key mask="A" key="F4">close</Key>
  <Key key="Home">exec:x-chip-close-game</Key>
  <Key key="XF86HomePage">exec:x-chip-close-game</Key>
  <Key key="XF86PowerOff">exec:x-chip-close-game</Key>
  <SnapMode distance="8">border</SnapMode>
  <MoveMode>opaque</MoveMode>
  <ResizeMode>opaque</ResizeMode>
</JWM>
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/geany.conf" <<'EOF'
[geany]
pref_main_load_session=false
pref_main_save_winpos=true
pref_main_confirm_exit=false
use_atomic_file_saving=false
editor_font=Luxi Mono 9
tagbar_font=Luxi Sans 9
msgwin_font=Luxi Mono 9
show_notebook_tabs=true
show_tab_cross=true
tab_pos_editor=2
show_editor_scrollbars=true
show_indent_guide=false
show_white_space=false
show_line_endings=false
show_markers_margin=false
show_linenumber_margin=false
line_wrapping=true
use_folding=false
pref_toolbar_show=false
pref_toolbar_append_to_menu=false
sidebar_visible=false
statusbar_visible=false
msgwindow_visible=false
fullscreen=false
geometry=0;0;474;212;0;
load_plugins=false
load_vte=false

[tools]
terminal_cmd=aterm -bg '#0F1716' -fg '#EAF2EF' -cr '#1F7A66' -e "/bin/sh %c"
browser_cmd=dillo
grep_cmd=grep

[files]
recent_files=
recent_projects=
current_page=-1
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/leafpadrc" <<'EOF'
0.8.19
474
212
Luxi Mono 9
1
0
0
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/pcmanfm.conf" <<'EOF'
[config]
bm_open_method=0

[volume]
mount_on_startup=1
mount_removable=1
autorun=1

[ui]
always_show_tabs=0
max_tab_chars=18
win_width=474
win_height=212
splitter_pos=105
media_in_new_tab=0
desktop_folder_new_win=0
change_tab_on_drop=1
close_on_unmount=1
focus_previous=0
side_pane_mode=places
view_mode=list
show_hidden=0
sort=name;ascending;
toolbar=navigation;home;
show_statusbar=0
pathbar_mode_buttons=0
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/dillorc" <<'EOF'
geometry=474x212+0+0
font_factor=0.85
font_min_size=6
font_max_size=14
small_icons=YES
panel_size=small
show_filemenu=YES
show_back=YES
show_forw=YES
show_home=YES
show_reload=YES
show_stop=YES
show_save=NO
show_bookmarks=NO
show_tools=NO
show_search=NO
show_help=NO
show_progress_box=NO
show_msg=NO
show_url=YES
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/gtkrc-2.0" <<'EOF'
gtk-font-name = "Luxi Sans 9"
gtk-icon-theme-name = "x-chip"
gtk-toolbar-style = GTK_TOOLBAR_ICONS
gtk-icon-sizes = "gtk-small-toolbar=16,16:gtk-large-toolbar=16,16:gtk-button=16,16:gtk-menu=16,16"

style "pocketclean"
{
  bg[NORMAL] = "#0F1716"
  fg[NORMAL] = "#EAF2EF"
  base[NORMAL] = "#6A7A75"
  text[NORMAL] = "#EAF2EF"
  bg[ACTIVE] = "#223331"
  fg[ACTIVE] = "#EAF2EF"
  bg[PRELIGHT] = "#1F7A66"
  fg[PRELIGHT] = "#0F1716"
  bg[SELECTED] = "#1F7A66"
  fg[SELECTED] = "#0F1716"
  bg[INSENSITIVE] = "#223331"
  fg[INSENSITIVE] = "#6A7A75"
}
class "*" style "pocketclean"
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/Xdefaults" <<'EOF'
Aterm*transparent: false
Aterm*inheritPixmap: false
Aterm*shading: 0
Aterm*fading: 0
Aterm*background: #0F1716
Aterm*foreground: #EAF2EF
Aterm*cursorColor: #1F7A66
Aterm*font: 8x13
Aterm*boldFont: 8x13
Aterm*scrollBar: true
Aterm*saveLines: 1000
EOF

    install_text 0644 "$RFS/usr/local/share/applications/x-chip-image.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=X-CHIP Image Viewer
Exec=x-chip-open-image %f
Icon=image-x-generic
Terminal=false
MimeType=image/png;image/jpeg;image/gif;image/webp;image/x-xpixmap;
NoDisplay=true
EOF

    install_text 0644 "$RFS/usr/local/share/applications/x-chip-video.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=X-CHIP Video Player
Exec=aterm -title Video -e x-chip-video play %f
Icon=video-x-generic
Terminal=false
MimeType=video/mp4;video/x-m4v;video/x-msvideo;video/quicktime;video/x-matroska;video/webm;video/mpeg;
NoDisplay=true
EOF

    install_text 0644 "$RFS/usr/local/share/applications/x-chip-music.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=X-CHIP Music Player
Exec=aterm -title Music -e x-chip-term-hold x-chip-music play %f
Icon=audio-x-generic
Terminal=false
MimeType=audio/mpeg;audio/mp3;
NoDisplay=true
EOF

    install_text 0644 "$RFS/usr/local/share/applications/x-chip-pdf.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=X-CHIP PDF Viewer
Exec=x-chip-open-pdf %f
Icon=application-pdf
Terminal=false
MimeType=application/pdf;
NoDisplay=true
EOF

    install_text 0644 "$RFS/usr/local/share/applications/x-chip-text.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=X-CHIP Text Editor
Exec=leafpad %f
Icon=text-x-generic
Terminal=false
MimeType=text/plain;text/markdown;application/x-shellscript;
NoDisplay=true
EOF

    install_text 0644 "$RFS/usr/local/share/applications/mimeapps.list" <<'EOF'
[Default Applications]
image/png=x-chip-image.desktop
image/jpeg=x-chip-image.desktop
image/gif=x-chip-image.desktop
image/webp=x-chip-image.desktop
image/x-xpixmap=x-chip-image.desktop
video/mp4=x-chip-video.desktop
video/x-m4v=x-chip-video.desktop
video/x-msvideo=x-chip-video.desktop
video/quicktime=x-chip-video.desktop
video/x-matroska=x-chip-video.desktop
video/webm=x-chip-video.desktop
video/mpeg=x-chip-video.desktop
audio/mpeg=x-chip-music.desktop
audio/mp3=x-chip-music.desktop
application/pdf=x-chip-pdf.desktop
text/plain=x-chip-text.desktop
text/markdown=x-chip-text.desktop
application/x-shellscript=x-chip-text.desktop
EOF

    install_text 0644 "$RFS/usr/local/share/applications/mimeinfo.cache" <<'EOF'
[MIME Cache]
image/png=x-chip-image.desktop;
image/jpeg=x-chip-image.desktop;
image/gif=x-chip-image.desktop;
image/webp=x-chip-image.desktop;
image/x-xpixmap=x-chip-image.desktop;
video/mp4=x-chip-video.desktop;
video/x-m4v=x-chip-video.desktop;
video/x-msvideo=x-chip-video.desktop;
video/quicktime=x-chip-video.desktop;
video/x-matroska=x-chip-video.desktop;
video/webm=x-chip-video.desktop;
video/mpeg=x-chip-video.desktop;
audio/mpeg=x-chip-music.desktop;
audio/mp3=x-chip-music.desktop;
application/pdf=x-chip-pdf.desktop;
text/plain=x-chip-text.desktop;
text/markdown=x-chip-text.desktop;
application/x-shellscript=x-chip-text.desktop;
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/mc-media.ext.ini" <<'EOF'
### x-chip media handlers ###

[x-chip images]
Regex=\.(png|jpe?g|gif|webp|xpm)$
RegexIgnoreCase=true
Open=sh -c 'x-chip-open-image "$MC_EXT_FILENAME"'
View=sh -c 'x-chip-open-image "$MC_EXT_FILENAME"'

[x-chip videos]
Regex=\.(mp4|m4v|avi|mov|mkv|webm|mpg|mpeg)$
RegexIgnoreCase=true
Open=sh -c 'x-chip-video play "$MC_EXT_FILENAME"'
View=sh -c 'x-chip-video play "$MC_EXT_FILENAME"'

[x-chip music]
Regex=\.(mp3)$
RegexIgnoreCase=true
Open=sh -c 'x-chip-music play "$MC_EXT_FILENAME"'
View=sh -c 'x-chip-music play "$MC_EXT_FILENAME"'

[x-chip pdf]
Regex=\.(pdf)$
RegexIgnoreCase=true
Open=sh -c 'x-chip-open-pdf "$MC_EXT_FILENAME"'
View=sh -c 'x-chip-open-pdf "$MC_EXT_FILENAME"'
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/gtk3-settings.ini" <<'EOF'
[Settings]
gtk-font-name = Luxi Sans 9
gtk-icon-theme-name = x-chip
gtk-theme-name = Adwaita
gtk-application-prefer-dark-theme = false
gtk-cursor-theme-name = Adwaita
EOF

    install_text 0644 "$RFS/usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example" <<'EOF'
Section "Device"
	Identifier "PocketCHIP fbturbo"
	Driver "fbturbo"
	Option "fbdev" "/dev/fb0"
	Option "SwapbuffersWait" "true"
EndSection
EOF
}

install_user_command_symlinks() {
    need_root install -d "$RFS/usr/local/bin"
    for tool in iw iwconfig wpa_cli; do
        need_root ln -sfn "../sbin/$tool" "$RFS/usr/local/bin/$tool"
    done

    install_text 0755 "$RFS/usr/local/bin/x-chip-load-rtl8812au" <<'EOF'
#!/bin/sh
set -eu
modprobe 8812au
echo "RTL8812AU module loaded"
echo "No WPA/DHCP started on this adapter; internal RTL8723BS remains primary."
iw dev 2>/dev/null || true
EOF
}

install_rtl8812au_hotplug() {
    need_root install -d "$RFS/etc/udev/rules.d" "$RFS/etc/modprobe.d" "$RFS/usr/local/sbin"

    install_text 0644 "$RFS/etc/modprobe.d/8812au.conf" <<'EOF'
# Keep the external RTL8812AU adapter responsive for scanning.
options 8812au rtw_power_mgnt=0 rtw_ips_mode=0
EOF

    install_text 0755 "$RFS/usr/local/sbin/x-chip-rtl8812au-hotplug" <<'EOF'
#!/bin/sh
HOTPLUG_ENABLED="@RTL8812AU_HOTPLUG@"
LOG=/var/log/rtl8812au-hotplug.log

[ "$HOTPLUG_ENABLED" = 1 ] || exit 0

{
	echo "=== rtl8812au hotplug $(date 2>/dev/null || true) ==="
	echo "ACTION=${ACTION:-}"
	echo "PRODUCT=${PRODUCT:-}"
	echo "DEVPATH=${DEVPATH:-}"

	if lsmod 2>/dev/null | grep -q '^8812au'; then
		echo "8812au already loaded"
	else
		modprobe 8812au && echo "loaded 8812au" || echo "WARN: failed to load 8812au"
	fi

	# Intentionally do not start WPA/DHCP here. The internal r8723bs interface
	# remains the primary SSH/network adapter; this USB adapter is secondary.
	iw dev 2>/dev/null || true
} >>"$LOG" 2>&1

exit 0
EOF
    need_root sed -i "s/@RTL8812AU_HOTPLUG@/${RTL8812AU_HOTPLUG:-1}/g" "$RFS/usr/local/sbin/x-chip-rtl8812au-hotplug"

    install_text 0644 "$RFS/etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules" <<'EOF'
# Load the optional RTL8812AU USB WiFi module when a Realtek USB adapter appears.
# Network management is not started here; the adapter remains secondary.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", RUN+="/usr/local/sbin/x-chip-rtl8812au-hotplug"
EOF
}

install_extra_firmware() {
    local src base dir file rel
    for src in \
        "$EXTRA_FIRMWARE_SOURCE" \
        "${EXTRA_FIRMWARE_SOURCE%/lib/firmware}/usr/lib/firmware" \
        "../flash/rootfs_trixie/usr/lib/firmware"; do
        case "$src" in
            /*) base=$src ;;
            *)  base="$HERE/$src" ;;
        esac
        [ -d "$base" ] || continue

        for dir in rtlwifi rtl_bt; do
            [ -d "$base/$dir" ] || continue
            while IFS= read -r file; do
                rel=${file#"$base/"}
                need_root install -d "$RFS/lib/firmware/$(dirname "$rel")"
                need_root install -m644 "$file" "$RFS/lib/firmware/$rel"
            done < <(find "$base/$dir" -maxdepth 1 \( -type f -o -type l \) -name 'rtl8723bs*.bin' | sort)
        done
    done
}

install_preseeded_firmware_fallback() {
    [ -s "$RFS/lib/firmware/rtlwifi/rtl8723bs_nic.bin" ] && return 0
    [ -f "$RFS/tce/optional/firmware-rtlwifi.tcz" ] || return 0
    command -v unsquashfs >/dev/null || {
        echo "WARN: unsquashfs missing; cannot extract rtl8723bs firmware from firmware-rtlwifi.tcz" >&2
        return 0
    }

    local tmp file rel
    tmp=$(mktemp -d)
    if ! unsquashfs -quiet -dest "$tmp" "$RFS/tce/optional/firmware-rtlwifi.tcz" >/dev/null; then
        rm -rf "$tmp"
        echo "WARN: could not extract firmware-rtlwifi.tcz" >&2
        return 0
    fi

    while IFS= read -r file; do
        rel=${file#"$tmp/"}
        case "$rel" in
            usr/local/lib/firmware/*) rel=${rel#usr/local/} ;;
            lib/firmware/*) ;;
            *) continue ;;
        esac
        need_root install -d "$RFS/$(dirname "$rel")"
        need_root install -m644 "$file" "$RFS/$rel"
    done < <(find "$tmp" -type f -path '*/firmware/rtlwifi/rtl8723bs*.bin' | sort)

    rm -rf "$tmp"
}

install_extra_modules() {
    local krel module vermagic
    krel="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
    module="$HERE/build/rtl8812au/8812au.ko"
    [ -f "$module" ] || return 0

    if command -v modinfo >/dev/null; then
        vermagic=$(modinfo -F vermagic "$module" 2>/dev/null || true)
        case "$vermagic" in
            "$krel "*) ;;
            *)
                echo "ERROR: $module vermagic '$vermagic' does not match '$krel'" >&2
                exit 1
                ;;
        esac
    fi

    need_root install -D -m644 "$module" "$RFS/lib/modules/$krel/extra/8812au.ko"
    need_root depmod -b "$RFS" "$krel"
}

preseed_tcz_extensions() {
    [ "${PRESEED_TCZ:-1}" = 1 ] || return 0
    command -v curl >/dev/null || { echo "need curl to preseed TinyCore extensions" >&2; exit 1; }

    local optional="$RFS/tce/optional"
    need_root install -d "$optional"
    declare -A seen=()

    copy_community_tcz_extensions() {
        local mode=${INCLUDE_COMMUNITY_TCZ:-auto}
        local src=${COMMUNITY_TCZ_DIR:-$HERE/dist/community-tcz}
        local app file copied=0
        [ "$mode" != 0 ] || return 0
        if [ ! -d "$src" ]; then
            [ "$mode" = 1 ] && {
                echo "ERROR: INCLUDE_COMMUNITY_TCZ=1 but $src does not exist" >&2
                echo "Run 'make community-tcz' before building the rootfs." >&2
                exit 1
            }
            return 0
        fi
        for app in tic80 goattracker sunvox pixitracker pixitracker-1bit pixilang mgba doom; do
            if [ ! -s "$src/$app.tcz" ]; then
                [ "$mode" = 1 ] && {
                    echo "ERROR: missing $src/$app.tcz" >&2
                    exit 1
                }
                continue
            fi
            echo ">> copy community extension $app.tcz"
            for file in "$app.tcz" "$app.tcz.dep" "$app.tcz.info" "$app.tcz.list" "$app.tcz.md5.txt"; do
                [ -e "$src/$file" ] || continue
                need_root install -m644 "$src/$file" "$optional/$file"
            done
            copied=1
        done
        [ "$copied" = 1 ] && echo ">> community extensions cached for click-to-load use"
    }

    download_optional() {
        local url=$1 dest=$2 tmp
        [ -s "$dest" ] && return 0
        tmp=$(mktemp)
        if curl -fsSL -o "$tmp" "$url"; then
            need_root install -m644 "$tmp" "$dest"
            rm -f "$tmp"
        else
            rm -f "$tmp"
            return 1
        fi
    }

    download_required() {
        local url=$1 dest=$2 tmp
        [ -s "$dest" ] && return 0
        tmp=$(mktemp)
        curl -fSL -o "$tmp" "$url"
        need_root install -m644 "$tmp" "$dest"
        rm -f "$tmp"
    }
    verify_tcz_md5() {
        local pkg=$1 md5file=$2 expected actual
        [ -s "$md5file" ] || return 0
        command -v md5sum >/dev/null || { echo "ERROR: md5sum is required to verify $pkg" >&2; exit 1; }
        expected=$(awk '{ print $1; exit }' "$md5file")
        [ -n "$expected" ] || return 0
        actual=$(md5sum "$optional/$pkg" | awk '{ print $1 }')
        [ "$actual" = "$expected" ] || {
            echo "ERROR: md5 mismatch for $pkg" >&2
            echo "expected: $expected" >&2
            echo "actual:   $actual" >&2
            exit 1
        }
    }

    scrub_kernel_placeholder_deps() {
        local depfile=$1 tmp
        [ -s "$depfile" ] || return 0
        if grep -q 'KERNEL' "$depfile"; then
            tmp=$(mktemp)
            grep -v 'KERNEL' "$depfile" >"$tmp" || true
            need_root install -m644 "$tmp" "$depfile"
            rm -f "$tmp"
        fi
    }

    download_tcz() {
        local pkg=$1 dep
        pkg=${pkg%%#*}
        pkg=${pkg//[$'\t\r\n ']/}
        [ -n "$pkg" ] || return 0
        [[ "$pkg" == *.tcz ]] || pkg="$pkg.tcz"
        case "$pkg" in
            *KERNEL*.tcz)
                echo ">> skip TinyCore kernel placeholder $pkg"
                return 0
                ;;
        esac
        [ -n "${seen[$pkg]:-}" ] && return 0
        seen[$pkg]=1

        echo ">> preseed $pkg"
        download_required "$TCZ_REPO/$pkg" "$optional/$pkg"
        download_optional "$TCZ_REPO/$pkg.dep" "$optional/$pkg.dep" || true
        scrub_kernel_placeholder_deps "$optional/$pkg.dep"
        download_optional "$TCZ_REPO/$pkg.md5.txt" "$optional/$pkg.md5.txt" || true
        verify_tcz_md5 "$pkg" "$optional/$pkg.md5.txt"
        download_optional "$TCZ_REPO/$pkg.info" "$optional/$pkg.info" || true

        if [ -s "$optional/$pkg.dep" ]; then
            while IFS= read -r dep; do
                download_tcz "$dep"
            done <"$optional/$pkg.dep"
        fi
    }

    copy_community_tcz_extensions

    while IFS= read -r ext; do
        download_tcz "$ext"
    done < tce/onboot.lst

    if [ -f tce/media.lst ]; then
        while IFS= read -r ext; do
            download_tcz "$ext"
        done < tce/media.lst
    fi

    if [ -f tce/xorg.lst ]; then
        while IFS= read -r ext; do
            download_tcz "$ext"
        done < tce/xorg.lst
    fi

    for depfile in "$optional/tic80.tcz.dep" "$optional/goattracker.tcz.dep" "$optional/sunvox.tcz.dep" "$optional/pixitracker.tcz.dep" "$optional/pixitracker-1bit.tcz.dep" "$optional/pixilang.tcz.dep" "$optional/mgba.tcz.dep" "$optional/doom.tcz.dep"; do
        [ -s "$depfile" ] || continue
        while IFS= read -r ext; do
            download_tcz "$ext"
        done < "$depfile"
    done

    need_root chown -R 0:0 "$RFS/tce"
}

materialize_tcz_runtime_extensions() {
    [ "${PRESEED_TCZ:-1}" = 1 ] || return 0
    command -v unsquashfs >/dev/null || {
        echo "ERROR: unsquashfs is required to materialize boot-critical TinyCore extensions" >&2
        exit 1
    }

    local optional="$RFS/tce/optional"
    local manifest_dir="$RFS/usr/local/share/x-chip"
    local manifest="$manifest_dir/materialized-tcz.lst"
    local tmp_manifest tmp_extract ext app depfile
    declare -A materialize_seen=()

    need_root install -d "$manifest_dir" "$RFS/usr/local/tce.installed"
    tmp_manifest=$(mktemp)

    normalize_tcz_name() {
        local name=$1
        name=${name%%#*}
        name=${name//[$'\t\r\n ']/}
        [ -n "$name" ] || return 1
        [[ "$name" == *.tcz ]] || name="$name.tcz"
        case "$name" in
            *KERNEL*.tcz) return 1 ;;
        esac
        printf '%s\n' "$name"
    }

    collect_tcz() {
        local name dep
        name=$(normalize_tcz_name "$1") || return 0
        [ -n "${materialize_seen[$name]:-}" ] && return 0
        materialize_seen[$name]=1
        [ -f "$optional/$name" ] || {
            echo "ERROR: cannot materialize missing /tce/optional/$name" >&2
            exit 1
        }
        depfile="$optional/$name.dep"
        if [ -s "$depfile" ]; then
            while IFS= read -r dep; do
                collect_tcz "$dep"
            done <"$depfile"
        fi
        printf '%s\n' "$name" >>"$tmp_manifest"
    }

    for ext in \
        openssh.tcz \
        bash.tcz \
        dhcpcd.tcz \
        wpa_supplicant.tcz \
        iw.tcz \
        wireless_tools.tcz; do
        collect_tcz "$ext"
    done

    if [ -f tce/xorg.lst ]; then
        while IFS= read -r ext; do
            collect_tcz "$ext"
        done < tce/xorg.lst
    fi

    sort -u "$tmp_manifest" | while IFS= read -r ext; do
        [ -n "$ext" ] || continue
        echo ">> materialize $ext"
        tmp_extract=$(mktemp -d)
        unsquashfs -quiet -force -dest "$tmp_extract" "$optional/$ext" >/dev/null
        need_root cp -a "$tmp_extract/." "$RFS/"
        rm -rf "$tmp_extract"
        app=${ext%.tcz}
        [ -e "$RFS/usr/local/tce.installed/$app" ] || need_root touch "$RFS/usr/local/tce.installed/$app"
    done

    need_root install -m644 "$tmp_manifest" "$manifest"
    rm -f "$tmp_manifest"
}

install_ca_certificates_bundle() {
    local cert_dir="$RFS/usr/local/share/ca-certificates"
    local conf_src="$cert_dir/files/ca-certificates.conf"
    local conf_dst="$RFS/usr/local/etc/ca-certificates.conf"
    local certs_dir="$RFS/usr/local/etc/ssl/certs"
    local tmp_bundle tmp_list rel cert

    [ -d "$cert_dir" ] || return 0

    need_root install -d \
        "$RFS/usr/local/etc" \
        "$RFS/usr/local/etc/ssl" \
        "$certs_dir" \
        "$RFS/usr/local/etc/pki/certs" \
        "$RFS/etc/ssl"

    if [ ! -s "$conf_dst" ] && [ -s "$conf_src" ]; then
        need_root install -m644 "$conf_src" "$conf_dst"
    fi

    tmp_bundle=$(mktemp)
    tmp_list=$(mktemp)
    if [ -s "$conf_dst" ]; then
        sed -e '/^$/d' -e '/^#/d' -e '/^!/d' "$conf_dst" >"$tmp_list"
    fi
    if [ ! -s "$tmp_list" ]; then
        find "$cert_dir" -type f -name '*.crt' | sed "s#^$cert_dir/##" | sort >"$tmp_list"
    fi

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        cert="$cert_dir/$rel"
        [ -f "$cert" ] || continue
        sed -e '$a\' "$cert" >>"$tmp_bundle"
    done <"$tmp_list"

    if [ ! -s "$tmp_bundle" ]; then
        rm -f "$tmp_bundle" "$tmp_list"
        echo "ERROR: ca-certificates.tcz was materialized but no CA bundle could be built" >&2
        exit 1
    fi

    need_root install -m644 "$tmp_bundle" "$certs_dir/ca-certificates.crt"
    need_root ln -sfn ca-certificates.crt "$certs_dir/ca-bundle.crt"
    need_root ln -sfn certs/ca-certificates.crt "$RFS/usr/local/etc/ssl/cacert.pem"
    need_root ln -sfn certs/ca-certificates.crt "$RFS/usr/local/etc/ssl/ca-bundle.crt"
    need_root ln -sfn ../../ssl/certs/ca-certificates.crt "$RFS/usr/local/etc/pki/certs/ca-bundle.crt"
    need_root rm -rf "$RFS/etc/ssl/certs"
    need_root ln -sfn /usr/local/etc/ssl/certs "$RFS/etc/ssl/certs"
    rm -f "$tmp_bundle" "$tmp_list"
}

prune_conflicting_xorg_defaults_from_rootfs() {
    need_root rm -f \
        "$RFS/usr/local/share/X11/xorg.conf.d/20-noglamor.conf" \
        "$RFS/etc/X11/xorg.conf.d/20-noglamor.conf"
}

compile_host_mime_database() {
    local mime_dir="$RFS/usr/local/share/mime"
    [ -d "$mime_dir/packages" ] || return 0
    if ! command -v update-mime-database >/dev/null 2>&1; then
        echo "WARN: update-mime-database not found on build host; first boot will generate MIME cache" >&2
        return 0
    fi
    echo ">> compile MIME database"
    update-mime-database "$mime_dir"
}

install_boot_runtime_script() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOSTNAME_VALUE="@HOSTNAME@"
RTL8812AU_AUTOLOAD_VALUE="@RTL8812AU_AUTOLOAD@"
RTL8812AU_HOTPLUG_VALUE="@RTL8812AU_HOTPLUG@"
LCD_BRIGHTNESS_VALUE="@LCD_BRIGHTNESS@"
DISPLAY_CONFIG=${X_CHIP_DISPLAY_CONFIG:-/usr/local/etc/x-chip/display.conf}
LOG=/opt/x-chip-boot.log
exec >>"$LOG" 2>&1
echo "=== x-chip boot runtime $(date 2>/dev/null || true) ==="

boot_seconds() {
	awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || echo 0
}

boot_stamp() {
	echo "[$(boot_seconds)s] $*"
}

boot_status() {
	msg="$*"
	boot_stamp "$msg"
	if [ -w /dev/tty1 ]; then
		{
			printf '\033[2J\033[H'
			printf 'X-CHIP TinyCore\n\n'
			printf '%s\n\n' "$msg"
			printf 'Please wait...\n'
		} >/dev/tty1 2>/dev/null || true
	fi
}

if ! grep -q ' /dev/shm ' /proc/mounts 2>/dev/null; then
	mkdir -p /dev/shm 2>/dev/null || true
	mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
fi
RUN_DIR=/dev/shm/x-chip
RUN_MARKER="$RUN_DIR/boot-ran"
RUN_LOCK="$RUN_DIR/boot.lock"
CONSOLE_READY="$RUN_DIR/console-ready"
TCE_READY="$RUN_DIR/tce-loaded"
mkdir -p "$RUN_DIR" 2>/dev/null || true
rm -rf /tmp/x-chip-firstboot-ran /tmp/x-chip-firstboot.lock 2>/dev/null || true

if [ -e "$RUN_MARKER" ]; then
	echo "x-chip boot runtime already ran this boot"
	exit 0
fi
if ! mkdir "$RUN_LOCK" 2>/dev/null; then
	echo "x-chip boot runtime already running"
	exit 0
fi
trap 'rmdir "$RUN_LOCK" 2>/dev/null || true' EXIT
touch "$RUN_MARKER" 2>/dev/null || true

hostname "$HOSTNAME_VALUE" 2>/dev/null || true
boot_status "Preparing system services"

silence_kernel_console() {
	dmesg -n 1 2>/dev/null || true
	if [ -w /proc/sys/kernel/printk ]; then
		echo '1 4 1 7' > /proc/sys/kernel/printk 2>/dev/null || true
	fi
}

ensure_devpts() {
	mkdir -p /dev/pts 2>/dev/null || true
	if ! grep -q ' /dev/pts ' /proc/mounts 2>/dev/null; then
		mount -t devpts devpts /dev/pts -o mode=620,ptmxmode=666 2>/dev/null || \
			mount -t devpts devpts /dev/pts 2>/dev/null || true
	fi
}

ensure_runtime_dirs() {
	mkdir -p /run /var/run /var/lock /var/run/dbus /var/run/dhcpcd \
		/var/run/tcebootload /var/run/wpa_supplicant 2>/dev/null || true
	chmod 755 /run /var/run /var/run/dbus /var/run/dhcpcd \
		/var/run/tcebootload /var/run/wpa_supplicant 2>/dev/null || true
	chmod 775 /var/lock 2>/dev/null || true
}

reset_tce_installed_markers() {
	[ -d /usr/local/tce.installed ] || return 0
	for marker in /usr/local/tce.installed/*; do
		[ -e "$marker" ] || continue
		ext="${marker##*/}.tcz"
		if [ -r /usr/local/share/x-chip/materialized-tcz.lst ] && grep -qxF "$ext" /usr/local/share/x-chip/materialized-tcz.lst; then
			continue
		fi
		[ -f "/tce/optional/$ext" ] && rm -f "$marker" 2>/dev/null || true
	done
}

prepare_tce_runtime() {
	TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo "@SSH_USER@")"
	id "$TC_USER" >/dev/null 2>&1 || TC_USER="@SSH_USER@"

	mkdir -p /usr/local/tce.installed /tmp/tcloop /tmp/tce/optional /tce/optional 2>/dev/null || true
	if [ -d /tce/optional ]; then
		rm -f /etc/sysconfig/tcedir 2>/dev/null || true
		ln -s /tce /etc/sysconfig/tcedir 2>/dev/null || true
	fi
	chgrp staff /usr/local/tce.installed /tmp/tcloop /tmp/tce /tmp/tce/optional /tce /tce/optional 2>/dev/null || true
	chmod g+w /usr/local/tce.installed /tmp/tcloop /tmp/tce /tmp/tce/optional /tce /tce/optional 2>/dev/null || true
	modprobe loop 2>/dev/null || true
	modprobe squashfs 2>/dev/null || true
}

load_tcz_onboot() {
	[ -f /tce/onboot.lst ] || return 0
	command -v tce-load >/dev/null 2>&1 || return 0
	TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo "@SSH_USER@")"
	id "$TC_USER" >/dev/null 2>&1 || TC_USER="@SSH_USER@"

	run_tce_load() {
		if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
			su "$TC_USER" -c "tce-load -il $1" >/dev/null 2>&1 || true
		else
			tce-load -il "$1" >/dev/null 2>&1 || true
		fi
	}

	load_tcz_one() {
		ext="$1"
		case "$ext" in
			''|\#*) return 0 ;;
		esac
		case "$ext" in
			*.tcz) app="${ext%.tcz}" ;;
			*) app="$ext"; ext="$ext.tcz" ;;
		esac
		[ -e "/usr/local/tce.installed/$app" ] && return 0
		if [ -f "/tce/optional/$ext" ]; then
			run_tce_load "/tce/optional/$ext"
		else
			run_tce_load "$ext"
		fi
	}

	while IFS= read -r ext; do
		load_tcz_one "$ext"
	done < /tce/onboot.lst
}

load_tcz_boot_core() {
	[ -f /tce/onboot.lst ] || return 0
	command -v tce-load >/dev/null 2>&1 || return 0
	for ext in \
		openssh.tcz \
		bash.tcz; do
		app="${ext%.tcz}"
		[ -e "/usr/local/tce.installed/$app" ] && continue
		TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo "@SSH_USER@")"
		id "$TC_USER" >/dev/null 2>&1 || TC_USER="@SSH_USER@"
		if [ -f "/tce/optional/$ext" ]; then
			su "$TC_USER" -c "tce-load -il /tce/optional/$ext" >/dev/null 2>&1 || true
		else
			su "$TC_USER" -c "tce-load -il $ext" >/dev/null 2>&1 || true
		fi
	done
}

load_tcz_onboot_background() {
	(
		load_tcz_onboot
		configure_power_management
		load_audio_modules
		start_wifi
		sync_time_background
		load_rtl8812au_if_present
		load_extra_wifi_modules
		start_ssh
		touch "$TCE_READY" 2>/dev/null || true
	) >/var/log/x-chip-tce-background.log 2>&1 &
}

start_usb_debug_gadget() {
	modprobe libcomposite 2>/dev/null || true
	mkdir -p /sys/kernel/config 2>/dev/null || true
	if ! grep -q ' /sys/kernel/config ' /proc/mounts 2>/dev/null; then
		mount -t configfs none /sys/kernel/config 2>/dev/null || true
	fi
	[ -d /sys/kernel/config/usb_gadget ] || {
		echo "WARN: usb gadget configfs not available"
		return 0
	}

	G=/sys/kernel/config/usb_gadget/xchip_tinycore
	mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" 2>/dev/null || return 0
	echo 0x1d6b > "$G/idVendor" 2>/dev/null || true
	echo 0x0104 > "$G/idProduct" 2>/dev/null || true
	echo 0x0100 > "$G/bcdDevice" 2>/dev/null || true
	echo 0x0200 > "$G/bcdUSB" 2>/dev/null || true
	echo xchip-tinycore > "$G/strings/0x409/serialnumber" 2>/dev/null || true
	echo NTC > "$G/strings/0x409/manufacturer" 2>/dev/null || true
	echo "CHIP TinyCore debug" > "$G/strings/0x409/product" 2>/dev/null || true
	echo "USB debug network" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
	echo 250 > "$G/configs/c.1/MaxPower" 2>/dev/null || true

	FUNC=
	if mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
		FUNC=rndis.usb0
	elif mkdir -p "$G/functions/ecm.usb0" 2>/dev/null; then
		FUNC=ecm.usb0
	else
		echo "WARN: no RNDIS/ECM gadget function available"
		return 0
	fi
	echo de:ad:be:ef:54:01 > "$G/functions/$FUNC/dev_addr" 2>/dev/null || true
	echo de:ad:be:ef:54:02 > "$G/functions/$FUNC/host_addr" 2>/dev/null || true
	[ -e "$G/configs/c.1/$FUNC" ] || ln -s "$G/functions/$FUNC" "$G/configs/c.1/$FUNC" 2>/dev/null || true

	if [ -e "$G/UDC" ]; then
		CURRENT_UDC="$(cat "$G/UDC" 2>/dev/null || true)"
	else
		CURRENT_UDC=
	fi
	if [ -z "$CURRENT_UDC" ]; then
		UDC="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
		[ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null || true
	fi

	i=0
	while [ "$i" -lt 10 ]; do
		[ -e /sys/class/net/usb0 ] && break
		i=$((i + 1))
		sleep 1
	done
	if [ -e /sys/class/net/usb0 ]; then
		ifconfig usb0 192.168.82.1 netmask 255.255.255.0 up 2>/dev/null || true
		echo "USB debug network ready on 192.168.82.1"
	else
		echo "WARN: usb0 did not appear"
	fi
	}

load_pocketchip_input_modules() {
	modprobe matrix-keymap 2>/dev/null || true
	modprobe tca8418_keypad 2>/dev/null || true
	modprobe sun4i-lradc-keys 2>/dev/null || true
	modprobe sun4i-ts 2>/dev/null || true
}

configure_power_management() {
	modprobe cpufreq-dt 2>/dev/null || true
	modprobe axp20x_battery 2>/dev/null || true
	modprobe axp20x_ac_power 2>/dev/null || true
	modprobe axp20x_usb_power 2>/dev/null || true
	modprobe axp20x_adc 2>/dev/null || true
	modprobe iio-hwmon 2>/dev/null || true
	modprobe sun4i-gpadc-iio 2>/dev/null || true
	modprobe nvmem_sunxi_sid 2>/dev/null || true
	modprobe sunxi_wdt 2>/dev/null || true

	for governor in ondemand conservative powersave; do
		for available in /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors; do
			[ -r "$available" ] || continue
			if grep -qw "$governor" "$available" 2>/dev/null; then
				for target in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
					[ -w "$target" ] && echo "$governor" > "$target" 2>/dev/null || true
				done
				echo "CPU governor set to $governor where available"
				return 0
			fi
		done
	done
}

load_audio_modules() {
	modprobe snd-simple-card 2>/dev/null || true
	modprobe snd-soc-simple-card 2>/dev/null || true
	modprobe sun4i-codec 2>/dev/null || true
	modprobe snd-soc-sun4i-codec 2>/dev/null || true
	modprobe sun4i-i2s 2>/dev/null || true
	modprobe snd-soc-sun4i-i2s 2>/dev/null || true
	modprobe sun4i-spdif 2>/dev/null || true
	modprobe snd-soc-sun4i-spdif 2>/dev/null || true
	modprobe snd-usb-audio 2>/dev/null || true
	modprobe snd-seq-midi 2>/dev/null || true
	modprobe snd-virmidi 2>/dev/null || true
	modprobe snd-pcm-oss 2>/dev/null || true
	modprobe snd-mixer-oss 2>/dev/null || true

	i=0
	while [ "$i" -lt 10 ]; do
		[ -r /proc/asound/cards ] && grep -q '^[[:space:]]*[0-9]' /proc/asound/cards 2>/dev/null && break
		i=$((i + 1))
		sleep 1
	done

	if command -v alsactl >/dev/null 2>&1; then
		alsactl init >/var/log/alsactl-init.log 2>&1 || true
	fi
	if command -v amixer >/dev/null 2>&1; then
		amixer set Master unmute >/dev/null 2>&1 || true
		amixer set Master 80% >/dev/null 2>&1 || true
		amixer set Headphone unmute >/dev/null 2>&1 || true
		amixer set Headphone 80% >/dev/null 2>&1 || true
		amixer set Speaker unmute >/dev/null 2>&1 || true
		amixer set Speaker 80% >/dev/null 2>&1 || true
		amixer set PCM 80% >/dev/null 2>&1 || true
		amixer set 'Power Amplifier Mute' on >/dev/null 2>&1 || true
		amixer set 'Power Amplifier Mixer' on >/dev/null 2>&1 || true
		amixer set 'Power Amplifier DAC' on >/dev/null 2>&1 || true
		amixer set 'Power Amplifier' 80% >/dev/null 2>&1 || true
		amixer set 'Left Mixer Left DAC' on >/dev/null 2>&1 || true
		amixer set 'Right Mixer Right DAC' on >/dev/null 2>&1 || true
	fi
}

start_wifi() {
	[ -r /etc/wpa_supplicant.conf ] || return 0
	modprobe r8723bs rtw_power_mgnt=0 rtw_ips_mode=0 2>/dev/null || modprobe r8723bs 2>/dev/null || true
	rfkill unblock wifi 2>/dev/null || true

	i=0
	while [ "$i" -lt 30 ]; do
		WIFI_IFACE="$(find_internal_wifi_iface)"
		[ -n "$WIFI_IFACE" ] && break
		i=$((i + 1))
		sleep 1
	done
	[ -n "$WIFI_IFACE" ] || {
		echo "WARN: internal r8723bs WiFi interface not found"
		return 0
	}

	ip link set "$WIFI_IFACE" up 2>/dev/null || ifconfig "$WIFI_IFACE" up 2>/dev/null || true
	if ! pidof wpa_supplicant >/dev/null 2>&1; then
		wpa_supplicant -B -i "$WIFI_IFACE" -c /etc/wpa_supplicant.conf >/var/log/wpa_supplicant.log 2>&1 || true
	fi

	if command -v dhcpcd >/dev/null 2>&1; then
		dhcpcd -q -t 20 "$WIFI_IFACE" >/var/log/dhcpcd-"$WIFI_IFACE".log 2>&1 || true
	elif command -v udhcpc >/dev/null 2>&1; then
		udhcpc -i "$WIFI_IFACE" -x "hostname:$HOSTNAME_VALUE" -b >/var/log/udhcpc-"$WIFI_IFACE".log 2>&1 || true
	fi
}

sync_time_background() {
	[ -x /usr/local/bin/x-chip-time ] || return 0
	/usr/local/bin/x-chip-time sync-background >/dev/null 2>&1 || true
}

find_internal_wifi_iface() {
	for iface_path in /sys/class/net/wlan* /sys/class/net/wlp*; do
		[ -e "$iface_path" ] || continue
		iface="${iface_path##*/}"
		driver=""
		if [ -r "$iface_path/device/uevent" ]; then
			driver="$(sed -n 's/^DRIVER=//p' "$iface_path/device/uevent" | head -n 1)"
		fi
		if [ -z "$driver" ] && [ -L "$iface_path/device/driver" ]; then
			driver_path="$(readlink "$iface_path/device/driver" 2>/dev/null || true)"
			driver="${driver_path##*/}"
		fi
		case "$driver" in
			r8723bs|rtl8723bs)
				printf '%s\n' "$iface"
				return 0
				;;
		esac
	done
	return 1
}

load_keymap() {
	[ -r /usr/share/kmap/pocketchip.kmap ] || return 0
	if command -v loadkmap >/dev/null 2>&1; then
		loadkmap < /usr/share/kmap/pocketchip.kmap >/var/log/loadkmap.log 2>&1 || true
	fi
}

saved_lcd_brightness() {
	[ -r "$DISPLAY_CONFIG" ] || return 1
	sed -n 's/^LCD_BRIGHTNESS=\([0-9][0-9]*\)$/\1/p' "$DISPLAY_CONFIG" | head -n 1
}

enable_display_console() {
	for backlight in /sys/class/backlight/*; do
		[ -e "$backlight" ] || continue
		[ -w "$backlight/bl_power" ] && echo 0 > "$backlight/bl_power" 2>/dev/null || true
		if [ -r "$backlight/max_brightness" ] && [ -w "$backlight/brightness" ]; then
			max_brightness="$(cat "$backlight/max_brightness" 2>/dev/null || echo 10)"
			[ -n "$max_brightness" ] || max_brightness=10
			min_brightness=1
			[ "$max_brightness" -lt "$min_brightness" ] && min_brightness=0
			brightness="$(saved_lcd_brightness 2>/dev/null || true)"
			[ -n "$brightness" ] || brightness="$LCD_BRIGHTNESS_VALUE"
			case "$brightness" in
				''|*[!0-9]*) brightness="$max_brightness" ;;
			esac
			[ "$brightness" -lt "$min_brightness" ] && brightness="$min_brightness"
			[ "$brightness" -gt "$max_brightness" ] && brightness="$max_brightness"
			echo "$brightness" > "$backlight/brightness" 2>/dev/null || true
			echo "LCD brightness set to $brightness/$max_brightness"
		fi
	done
	for fbblank in /sys/class/graphics/fb*/blank; do
		[ -w "$fbblank" ] && echo 0 > "$fbblank" 2>/dev/null || true
	done
}

load_extra_wifi_modules() {
	[ "$RTL8812AU_AUTOLOAD_VALUE" = 1 ] || {
		echo "RTL8812AU boot autoload disabled; hotplug=$RTL8812AU_HOTPLUG_VALUE"
		return 0
	}
	modprobe 8812au >/var/log/modprobe-8812au.log 2>&1 || true
}

load_rtl8812au_if_present() {
	[ "$RTL8812AU_HOTPLUG_VALUE" = 1 ] || return 0
	for dev in /sys/bus/usb/devices/*; do
		[ -r "$dev/idVendor" ] || continue
		[ "$(cat "$dev/idVendor" 2>/dev/null)" = "0bda" ] || continue
		echo "Realtek USB device present; loading RTL8812AU secondary adapter support"
		/usr/local/sbin/x-chip-rtl8812au-hotplug >/dev/null 2>&1 || modprobe 8812au >/var/log/modprobe-8812au.log 2>&1 || true
		return 0
	done
}

start_desktop() {
	[ -x /usr/local/bin/x-chip-desktop-start ] || return 0
	echo "Starting default desktop"
	/usr/local/bin/x-chip-desktop-start --boot >/var/log/x-chip-desktop.log 2>&1 || \
		echo "WARN: desktop autostart failed; see /var/log/x-chip-desktop.log"

	desktop_ready() {
		[ -S /tmp/.X11-unix/X0 ] || return 1
		pidof Xorg >/dev/null 2>&1 || return 1
		pidof jwm >/dev/null 2>&1 || pidof flwm >/dev/null 2>&1
	}

	wait_for_desktop() {
		i=0
		while [ "$i" -lt 15 ]; do
			desktop_ready && return 0
			i=$((i + 1))
			sleep 1
		done
		return 1
	}

	wait_for_desktop && {
		echo "Desktop Xorg and window manager ready"
		return 0
	}

	echo "WARN: desktop not detected after launch; retrying once"
	/usr/local/bin/x-chip-desktop-start --boot >>/var/log/x-chip-desktop.log 2>&1 || \
		echo "WARN: desktop autostart retry failed; see /var/log/x-chip-desktop.log"
	wait_for_desktop && echo "Desktop Xorg and window manager ready after retry" || \
		echo "WARN: desktop still not ready after retry; see /var/log/x-chip-desktop.log"
}

ensure_ssh_host_keys() {
	command -v ssh-keygen >/dev/null 2>&1 || return 0
	mkdir -p /usr/local/etc/ssh
	[ -f /usr/local/etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /usr/local/etc/ssh/ssh_host_ed25519_key
	[ -f /usr/local/etc/ssh/ssh_host_rsa_key ] || ssh-keygen -q -t rsa -b 3072 -N '' -f /usr/local/etc/ssh/ssh_host_rsa_key
}

start_ssh() {
	lock_dir="${RUN_DIR:-/dev/shm/x-chip}/ssh.lock"
	mkdir -p "${lock_dir%/*}" 2>/dev/null || true
	if ! mkdir "$lock_dir" 2>/dev/null; then
		return 0
	fi
	ensure_ssh_host_keys
	if pidof sshd >/dev/null 2>&1; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	fi
	if [ -x /usr/local/etc/init.d/openssh ]; then
		/usr/local/etc/init.d/openssh start >/var/log/openssh.log 2>&1 || true
	elif command -v sshd >/dev/null 2>&1; then
		sshd >/var/log/openssh.log 2>&1 || true
	fi
	rmdir "$lock_dir" 2>/dev/null || true
}

silence_kernel_console
ensure_devpts
ensure_runtime_dirs
prepare_tce_runtime
reset_tce_installed_markers
boot_stamp "Runtime directories and TinyCore state ready"
load_pocketchip_input_modules
load_keymap
enable_display_console
boot_status "Console, keyboard, and display ready"
touch "$CONSOLE_READY" 2>/dev/null || true
start_usb_debug_gadget &
boot_stamp "USB debug network start requested"
boot_status "Loading SSH boot core"
load_tcz_boot_core
boot_stamp "SSH boot core loaded"
start_ssh
boot_stamp "SSH service requested"
load_tcz_onboot_background
boot_stamp "Background extension load requested"
boot_status "Starting desktop on VT2"
start_desktop
boot_status "Desktop ready on VT2"
boot_stamp "Boot runtime complete"
EOF
    sed -i "s/@HOSTNAME@/$CHIP_HOSTNAME/g" "$tmp"
    sed -i "s/@SSH_USER@/$SSH_USER/g" "$tmp"
    sed -i "s/@RTL8812AU_AUTOLOAD@/${RTL8812AU_AUTOLOAD:-0}/g" "$tmp"
    sed -i "s/@RTL8812AU_HOTPLUG@/${RTL8812AU_HOTPLUG:-1}/g" "$tmp"
    sed -i "s/@LCD_BRIGHTNESS@/${LCD_BRIGHTNESS:-6}/g" "$tmp"
    need_root rm -f "$RFS/opt/x-chip-firstboot.sh"
    need_root install -m755 "$tmp" "$RFS/opt/x-chip-boot.sh"
    rm -f "$tmp"

    need_root touch "$RFS/opt/bootlocal.sh"
    tmp=$(mktemp)
    awk '
        $0 == "/usr/local/etc/init.d/openssh start" { next }
        $0 == "/opt/x-chip-firstboot.sh" { next }
        $0 == "/opt/x-chip-boot.sh" { next }
        $0 ~ /^# --- x-chip.*(firstboot|boot runtime).*---$/ { next }
        { print }
    ' "$RFS/opt/bootlocal.sh" >"$tmp"
    need_root install -m755 "$tmp" "$RFS/opt/bootlocal.sh"
    rm -f "$tmp"
    need_root chown 0:0 "$RFS/opt/bootlocal.sh" 2>/dev/null || true
    need_root chmod +x "$RFS/opt/bootlocal.sh"
    if ! need_root grep -q '/opt/x-chip-boot.sh' "$RFS/opt/bootlocal.sh"; then
        need_root tee -a "$RFS/opt/bootlocal.sh" >/dev/null <<'EOF'
# --- x-chip boot runtime ---
/opt/x-chip-boot.sh
EOF
    fi

    need_root install -d "$RFS/usr/local/etc/ssh"
    local password_auth
    password_auth=no
    [ "$SSH_PASSWORD_AUTH" = 1 ] && password_auth=yes
    install_text 0644 "$RFS/usr/local/etc/ssh/sshd_config" <<EOF
Port 22
Protocol 2
HostKey /usr/local/etc/ssh/ssh_host_ed25519_key
HostKey /usr/local/etc/ssh/ssh_host_rsa_key
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication $password_auth
PermitEmptyPasswords no
PermitRootLogin prohibit-password
UseDNS no
Subsystem sftp internal-sftp
EOF

    need_root touch "$RFS/opt/.filetool.lst"
    tmp=$(mktemp)
    awk '$0 != "opt/x-chip-firstboot.sh" { print }' "$RFS/opt/.filetool.lst" >"$tmp"
    need_root install -m644 "$tmp" "$RFS/opt/.filetool.lst"
    rm -f "$tmp"
    for entry in \
        "etc/hostname" \
        "etc/hosts" \
        "etc/os-release" \
        "etc/issue" \
        "etc/motd" \
        "etc/modprobe.conf" \
        "etc/modprobe.d/8812au.conf" \
        "etc/modprobe.d/r8723bs.conf" \
        "etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules" \
        "etc/wpa_supplicant.conf" \
        "home/$SSH_USER/.ssh" \
        "root/.ssh" \
        "usr/local/etc/ssh" \
        "usr/share/kmap/pocketchip.kmap" \
        "usr/share/kmap/pocketchip.loadkeys" \
        "usr/local/etc/x-chip" \
        "usr/local/bin/x-chip-keyboard-status" \
        "usr/local/bin/x-chip-audio-status" \
        "usr/local/bin/x-chip-power-status" \
        "usr/local/bin/x-chip-term-hold" \
        "usr/local/bin/x-chip-status" \
        "usr/local/bin/x-chip-calc" \
        "usr/local/bin/x-chip-time" \
        "usr/local/bin/x-chip-open" \
        "usr/local/bin/x-chip-open-image" \
        "usr/local/bin/x-chip-open-pdf" \
        "usr/local/bin/x-chip-music" \
        "usr/local/bin/x-chip-video" \
        "usr/local/bin/xdg-open" \
        "usr/local/bin/x-chip-tic80" \
        "usr/local/bin/x-chip-goattracker" \
        "usr/local/bin/x-chip-sunvox" \
        "usr/local/bin/x-chip-virtual-ans" \
        "usr/local/bin/x-chip-pixitracker" \
        "usr/local/bin/x-chip-pixitracker-1bit" \
        "usr/local/bin/x-chip-pixilang" \
        "usr/local/bin/x-chip-mgba" \
        "usr/local/bin/x-chip-pico8" \
        "usr/local/bin/x-chip-games" \
        "usr/local/bin/x-chip-doom" \
        "usr/local/bin/x-chip-desktop-stats" \
        "usr/local/bin/x-chip-logs" \
        "usr/local/bin/x-chip-brightness" \
        "usr/local/bin/x-chip-wifi-menu" \
        "usr/local/bin/x-chip-media-on" \
        "usr/local/bin/x-chip-startx" \
        "usr/local/bin/x-chip-desktop-start" \
        "usr/local/bin/x-chip-gtk-cache" \
        "usr/local/bin/x-chip-close-app" \
        "usr/local/bin/x-chip-close-game" \
        "usr/local/bin/x-chip-game-launch" \
        "usr/local/bin/x-chip-x-apply-calibration" \
        "usr/local/bin/x-chip-x-keymap" \
        "usr/local/bin/x-chip-touch-calibrate" \
        "usr/local/bin/x-chip-xorg-launch-vt" \
        "usr/local/bin/x-chip-xorg-session" \
        "usr/local/etc/X11/xorg.conf.d" \
        "etc/X11/xorg.conf.d" \
        "usr/local/share/x-chip/xorg" \
        "usr/local/share/applications" \
        "usr/local/share/x-chip/tic80-carts.tsv" \
        "usr/local/share/x-chip/gameboy-homebrew.tsv" \
        "usr/local/share/x-chip/xorg/touchscreen-calibration.matrix" \
        "usr/local/share/x-chip/xorg/pocketchip.xmodmap" \
        "usr/local/sbin/x-chip-rtl8812au-hotplug" \
        "opt/x-chip-boot.sh" \
        "opt/x-chip-autologin.sh" \
        "opt/x-chip-tty1-getty.sh" \
        "opt/bootlocal.sh"; do
        need_root grep -qxF "$entry" "$RFS/opt/.filetool.lst" 2>/dev/null || \
            echo "$entry" | need_root tee -a "$RFS/opt/.filetool.lst" >/dev/null
    done
}

# 1. u-boot boot script.
"$MKIMAGE" -A arm -O linux -T script -C none \
    -d boot/boot.cmd "$RFS/boot/boot.scr"

# 2. tce mirror + onboot extension list (pulled on first online boot).
need_root install -d "$RFS/tce/optional"
need_root cp tce/onboot.lst "$RFS/tce/onboot.lst"
[ -f tce/media.lst ] && need_root cp tce/media.lst "$RFS/tce/media.lst"
[ -f tce/xorg.lst ] && need_root cp tce/xorg.lst "$RFS/tce/xorg.lst"
need_root install -d "$RFS/opt"
echo "$TC_MIRROR" | need_root tee "$RFS/opt/tcemirror" >/dev/null

# 3. Runtime identity, SSH, WiFi and local extensions.
install_runtime_identity
install_os_branding
install_runtime_mounts
install_console_config
patch_tinycore_tce_setup
patch_tinycore_tc_config
write_wifi_config
install_board_runtime_config
install_keymap
install_keyboard_debug_tools
install_hardware_debug_tools
install_media_tools
install_xorg_desktop_tools
install_user_command_symlinks
install_rtl8812au_hotplug
install_extra_firmware
install_extra_modules
create_static_dev_nodes
install_early_debug
preseed_tcz_extensions
materialize_tcz_runtime_extensions
install_ca_certificates_bundle
prune_conflicting_xorg_defaults_from_rootfs
install_preseeded_firmware_fallback
install_boot_runtime_script
compile_host_mime_database

# 4. pack (numeric owners; the flasher rebuilds the UBIFS from this tree).
normalize_rootfs_metadata
( cd "$RFS" && tar --numeric-owner -czf "$HERE/$OUT" . )
need_root chown "$(id -u):$(id -g)" "$HERE/$OUT" 2>/dev/null || true
for required in ./bin/busybox ./sbin/init ./init ./etc/inittab ./etc/init.d/tc-config; do
    tar -tzf "$HERE/$OUT" "$required" >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing $required" >&2
        exit 1
    }
done
for required in \
    ./boot/zImage \
    ./boot/boot.scr \
    ./boot/sun5i-r8-chip.dtb \
    ./opt/x-chip-boot.sh \
    ./opt/x-chip-autologin.sh \
    ./opt/x-chip-tty1-getty.sh \
    ./usr/local/bin/x-chip-keyboard-status \
    ./usr/local/bin/x-chip-audio-status \
    ./usr/local/bin/x-chip-power-status \
    ./usr/local/bin/x-chip-term-hold \
    ./usr/local/bin/x-chip-mc \
    ./usr/local/bin/x-chip-status \
    ./usr/local/bin/x-chip-calc \
    ./usr/local/bin/x-chip-time \
    ./usr/local/bin/x-chip-open \
    ./usr/local/bin/x-chip-open-image \
    ./usr/local/bin/x-chip-open-pdf \
    ./usr/local/bin/x-chip-music \
    ./usr/local/bin/x-chip-video \
    ./usr/local/bin/xdg-open \
    ./usr/local/bin/x-chip-tic80 \
    ./usr/local/bin/x-chip-goattracker \
    ./usr/local/bin/x-chip-sunvox \
    ./usr/local/bin/x-chip-virtual-ans \
    ./usr/local/bin/x-chip-pixitracker \
    ./usr/local/bin/x-chip-pixitracker-1bit \
    ./usr/local/bin/x-chip-pixilang \
    ./usr/local/bin/x-chip-mgba \
    ./usr/local/bin/x-chip-pico8 \
    ./usr/local/bin/x-chip-games \
    ./usr/local/bin/x-chip-doom \
    ./usr/local/bin/x-chip-desktop-stats \
    ./usr/local/bin/x-chip-logs \
    ./usr/local/bin/x-chip-brightness \
    ./usr/local/bin/x-chip-wifi-menu \
    ./usr/local/bin/x-chip-media-on \
    ./usr/local/bin/x-chip-startx \
    ./usr/local/bin/x-chip-desktop-start \
    ./usr/local/bin/x-chip-gtk-cache \
    ./usr/local/bin/x-chip-close-app \
    ./usr/local/bin/x-chip-close-game \
    ./usr/local/bin/x-chip-game-launch \
    ./usr/local/bin/x-chip-x-apply-calibration \
    ./usr/local/bin/x-chip-touch-calibrate \
    ./usr/local/bin/x-chip-xorg-launch-vt \
    ./usr/local/bin/x-chip-xorg-session \
    ./usr/local/sbin/x-chip-rtl8812au-hotplug \
    ./etc/modprobe.d/8812au.conf \
    ./etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules \
    ./usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf \
    ./etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf \
    ./usr/local/share/x-chip/tic80-carts.tsv \
    ./usr/local/share/x-chip/gameboy-homebrew.tsv \
    ./usr/local/share/x-chip/xorg/touchscreen-calibration.matrix \
    ./usr/local/share/x-chip/xorg/jwmrc \
    ./usr/local/share/x-chip/xorg/mc.ini \
    ./usr/local/share/mc/skins/pocketclean256.ini \
    ./usr/local/share/x-chip/xorg/wallpapers/pocket-core.png \
    ./usr/local/share/x-chip/xorg/Xdefaults \
    ./usr/local/share/x-chip/xorg/mc-media.ext.ini \
    ./usr/local/share/applications/x-chip-image.desktop \
    ./usr/local/share/applications/x-chip-video.desktop \
    ./usr/local/share/applications/x-chip-music.desktop \
    ./usr/local/share/applications/x-chip-pdf.desktop \
    ./usr/local/share/applications/x-chip-text.desktop \
    ./usr/local/share/applications/mimeapps.list \
    ./usr/local/share/applications/mimeinfo.cache \
    ./usr/local/share/mime/mime.cache \
    ./home/$SSH_USER/Pictures/red-hood-field.jpeg \
    ./home/$SSH_USER/Videos/pocket-video-demo.mp4 \
    ./home/$SSH_USER/Videos/night-lamp-dream.mp4 \
    ./home/$SSH_USER/Music/dreamscape-sample.mp3 \
    ./usr/local/share/x-chip/xorg/icons/menu.xpm \
    ./usr/local/share/icons/x-chip/index.theme \
    ./usr/local/share/icons/x-chip/16x16/places/folder.xpm \
    ./usr/local/etc/x-chip/display.conf \
    ./usr/local/etc/x-chip/desktop.conf \
    ./usr/local/etc/x-chip/desktop-stats.conf \
    ./usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example \
    ./usr/local/etc/ssh/sshd_config \
    ./home/$SSH_USER/.ssh/authorized_keys \
    ./home/$SSH_USER/Pictures \
    ./home/$SSH_USER/Videos \
    ./home/$SSH_USER/Music \
    ./home/$SSH_USER/Downloads \
    ./usr/share/kmap/pocketchip.kmap \
    ./lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo \
    ./lib/firmware/rtlwifi/rtl8723bs_nic.bin \
    ./tce/onboot.lst \
    ./tce/media.lst \
    ./tce/xorg.lst; do
    tar -tzf "$HERE/$OUT" "$required" >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing $required" >&2
        exit 1
    }
done
if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
    tar -tzf "$HERE/$OUT" ./etc/wpa_supplicant.conf >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing WiFi config" >&2
        exit 1
    }
fi
if [ "${RTL8812AU_BUILD:-1}" = 1 ]; then
    tar -tzf "$HERE/$OUT" "./lib/modules/${KERNEL_VERSION}${KERNEL_LOCALVERSION}/extra/8812au.ko" >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing RTL8812AU module" >&2
        exit 1
    }
fi

"$HERE/scripts/07-verify-rootfs.sh" "$HERE/$OUT"

echo ">> wrote $HERE/$OUT"
echo ">> flash: ../x-chip-tools/flash-live.sh $OUT"
