# CHIP NAND boot script for TinyCore.
# Mirrors the working x-chip-os Debian boot contract. U-Boot has already mounted
# the rootfs UBIFS volume to load this script, so keep the script focused on
# loading this image's kernel and DTB.

setenv bootargs 'console=tty0 console=ttyS0,115200 loglevel=7 printk.time=1 audit=0 ubi.mtd=4 root=ubi0:rootfs rootfstype=ubifs rw rootwait panic=10 user=chip tce=/tce base video=Unknown-1:480x272e video=Composite-1:d nozswap nortc norestore nofstab nodhcp'

ubifsload 0x42000000 /boot/zImage
ubifsload 0x43000000 /boot/sun5i-r8-chip.dtb

# --- DIP device-tree overlay auto-select ------------------------------------
# Copied from the known-good x-chip-os boot flow, with paths adjusted to this
# TinyCore rootfs. EEPROM header (big-endian): magic 'CHIP'(4) ver(1) VID(4)
# PID(2) product-version(1). NTC VID ends in 0x1a at byte 8; PocketCHIP is
# PID 1, and its product-version byte at offset 11 picks the keyboard matrix
# (48 = v72, 49 = v73). Source Parts (VID ...0x1b) product 10 is the
# Popcorn/Stove HDMI DIP.
setenv dipdir /lib/firmware/nextthingco/chip/early
if test -z "${dipovl}" && w1 read 0 0 0 0x80 0x45000000; then
	if itest.l *0x45000000 == 0x50494843; then
		echo "DIP id header (magic/ver/VID@5/PID@9/pver@11):"
		md.b 0x45000000 0x10
		if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x01; then setenv dipovl ${dipdir}/x-chip-pocketchip.dtbo; fi
		if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x01 && itest.b *0x4500000b == 0x30; then setenv dipovl ${dipdir}/x-chip-pocketchip-v72.dtbo; fi
		if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x02; then setenv dipovl ${dipdir}/x-chip-dip-vga.dtbo;    fi
		if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x03; then setenv dipovl ${dipdir}/x-chip-dip-hdmi.dtbo;   fi
		if itest.b *0x45000008 == 0x1b && itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x0a; then setenv dipovl ${dipdir}/x-chip-dip-hdmi-popcorn.dtbo; fi
		if test -n "${dipovl}"; then echo "DIP: selected ${dipovl}"; else echo "DIP: no overlay for this PID"; fi
	else
		echo "DIP: no CHIP header (no/foreign DIP)"
	fi
fi

# PocketCHIP is the target device for this image. If the DIP EEPROM read fails
# or returns an unknown PID, still apply the PocketCHIP LCD/keypad overlay so
# local display bring-up does not silently fall back to base CHIP.
if test -z "${dipovl}"; then
	setenv dipovl ${dipdir}/x-chip-pocketchip.dtbo
	echo "DIP: defaulting to PocketCHIP overlay ${dipovl}"
fi

if test -n "${dipovl}"; then
	echo "DIP: applying overlay ${dipovl}"
	fdt addr 0x43000000
	fdt resize 0x4000
	if ubifsload 0x44000000 ${dipovl} && fdt apply 0x44000000; then
		echo "DIP: overlay applied"
	else
		echo "DIP: overlay failed; booting base dtb"
		ubifsload 0x43000000 /boot/sun5i-r8-chip.dtb
	fi
fi

bootz 0x42000000 - 0x43000000
