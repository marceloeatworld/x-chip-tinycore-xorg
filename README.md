# x-chip-tinycore-xorg

A small, fast Linux for the NextThing PocketCHIP (and CHIP), built on TinyCore
Linux with a lightweight Xorg/JWM desktop and a modern mainline kernel.

- Linux `6.18.37` (latest longterm) built for the Allwinner R8
- TinyCore/CorePure armhf 16.x userland, about 55 MB RAM in use at the desktop
- Boots from NAND, flashed once over USB, then updates itself over WiFi
- WiFi, SSH, serial console, and USB debug networking out of the box
- Games (Doom, TIC-80, Game Boy) and music tools (SunVox, PixiTracker,
  GoatTracker, Pixilang) available from the menus

## Live PocketCHIP Preview

These are direct captures from the real PocketCHIP screen, not mockups. The
first capture shows the desktop monitor view: Xorg/JWM, SSH/runtime services,
and `htop` running on the `480x272` LCD.

![PocketCHIP TinyCore CPU and system monitor](docs/assets/pocket-readme-cpu.png)

| Desktop | Dillo | Games |
| --- | --- | --- |
| <img src="docs/assets/pocket-readme-screen.png" alt="PocketCHIP TinyCore desktop" width="240"> | <img src="docs/assets/pocket-readme-dillo.png" alt="Dillo on PocketCHIP TinyCore" width="240"> | <img src="docs/assets/pocket-readme-game.png" alt="Game menu on PocketCHIP TinyCore" width="240"> |

SunVox and Doom running fullscreen:

<img src="docs/assets/pocket-readme-music.png" alt="SunVox music tool on PocketCHIP TinyCore" width="480">
<img src="docs/assets/pocket-readme-doom.png" alt="Doom fullscreen on PocketCHIP TinyCore" width="480">

## For Users

1. [Flash the image](#1-flash-the-image) (once, needs a Linux PC)
2. [First boot](#2-first-boot) (login, WiFi, password)
3. [Update without reflashing](#3-update-without-reflashing)
4. [Install more software](#4-install-more-software)
5. [Desktop guide](#5-desktop-guide)
6. [Games and music](#6-games-and-music)

Builders and contributors: see [Build It Yourself](#build-it-yourself),
[Hardware Support](#hardware-support), and [Reference](#reference) below.

## 1. Flash the Image

You need a Linux PC and one jumper wire. Flashing erases the PocketCHIP NAND.
The flasher always finds the latest release by itself, so these commands never
change:

<https://github.com/marceloeatworld/x-chip-tinycore-xorg/releases/latest>

On Ubuntu/Debian, copy and paste:

```sh
sudo apt-get update
sudo apt-get install -y git curl ca-certificates

git clone https://github.com/marceloeatworld/x-chip-tinycore-xorg.git
cd x-chip-tinycore-xorg

./scripts/flash-release-pocketchip.sh --install-deps
```

On NixOS:

```sh
git clone https://github.com/marceloeatworld/x-chip-tinycore-xorg.git
cd x-chip-tinycore-xorg

nix shell nixpkgs#ubootTools nixpkgs#sunxi-tools -c ./scripts/flash-release-pocketchip.sh
```

The script downloads the release image and its `.sha256`, verifies everything
(including the flashing helper downloads, against SHA256 values pinned in
`config.env`), installs or checks the flashing tools, then asks you to type
`FLASH` before touching the device. You never need to look up checksums
yourself.

Put the PocketCHIP in flashing (FEL) mode:

1. Power the PocketCHIP off.
2. Find the **FEL** and **GND** pins or pads on the CHIP board.
3. Put one jumper wire between **FEL** and **GND**. Any **GND** pin is fine.
4. Keep **FEL** connected to **GND**, then plug the CHIP/PocketCHIP micro-USB
   cable into the Linux PC.
5. Run the flash command above and type `FLASH` when asked.
6. When the script prints `flash complete`, unplug USB, remove the jumper,
   then power on normally.

Do not connect **FEL** to **5V**, **VBAT**, or **3V3**. It only needs to touch
**GND** while the device starts in FEL mode. An interrupted flash is not
dangerous: FEL mode lives in the CPU ROM, just reconnect the jumper and flash
again.

Useful variants:

```sh
./scripts/flash-release-pocketchip.sh --dry-run     # download and verify only
./scripts/flash-release-pocketchip.sh --preflight   # also run the low-level checks
./scripts/flash-release-pocketchip.sh --tag TAG     # flash a specific release
```

If the script reports a missing NAND SPL image builder, your `sunxi-tools`
package is incomplete. Newer U-Boot builds provide the same tool as
`sunxi-spl-image-builder`; the scripts accept either name, and honor
`SNIB=/path/to/tool` for a custom build.

Advanced: if the PocketCHIP is plugged into another Linux machine (for example
a Raspberry Pi), flash through it over SSH:

```sh
FLASH_HOST=my-linux-host ./scripts/05-flash-via-host.sh --flash
```

## 2. First Boot

The device boots to the JWM desktop by itself. Defaults:

- User: `chip`, password: `chip` (also the sudo user; sudo asks no password)
- Hostname: `chip`

Connect to WiFi from the desktop: `Menu > Network > WiFi Setup`, pick your
network, type the password on the device. The connection is saved and comes
back after reboot. The clock sets itself automatically: it starts at the image
build date and syncs over the internet as soon as WiFi works (the CHIP has no
clock battery).

SSH works two ways:

- Over the USB cable, from the PC it is plugged into: `ssh chip@192.168.82.1`
- Over WiFi, once connected: `ssh chip@<the device IP>` (shown in
  `Menu > Network > WiFi Status`)

Change the password after the first boot:

```sh
passwd
```

## 3. Update Without Reflashing

Flashing is only needed once. After that, new releases install over WiFi
directly on the PocketCHIP, keeping your files, WiFi setup, and SSH keys:

```sh
sudo x-chip-update
```

There is also a `System Update` entry in `Menu > Pocket`. The command checks
GitHub for the latest release, downloads its update pack (much smaller than
the full image), verifies the SHA256, then updates the kernel, system scripts,
and the bundled apps. `/home` is never touched. Reboot when it finishes.

```sh
sudo x-chip-update --check      # only report whether an update exists
sudo x-chip-update --rollback   # boot the previous kernel if an update misbehaves
```

TinyCore packages themselves update separately with `tce-update` (see the next
section). A full reflash is only needed again for bootloader or
partition-layout changes; release notes will say so when that happens.

## 4. Install More Software

The running system uses TinyCore extensions (`.tcz`) as its package format.
No rebuild or reflash needed:

```sh
tce-load -w -i nano.tcz     # install one package, kept across reboots
tce-ab                      # browse and install interactively
```

Keep installed packages up to date:

```sh
sudo tce-update query /tce/optional          # check for updates
sudo tce-update update /tce/optional/nano.tcz # update one package
sudo update-everything                        # update everything cached
```

Run full updates from a console, not while using the desktop, and reboot
afterwards. If `update-everything` says a local community package such as
`doom.tcz`, `tic80.tcz`, `goattracker.tcz`, or `mgba.tcz` is deprecated,
answer `n` to keep it: those are local extensions, not TinyCore repo packages,
and `x-chip-update` is what updates them.

## 5. Desktop Guide

TinyCore shows boot logs, prepares the console and services, then starts the
fbdev/JWM desktop on VT2. The console, USB debug, WiFi, and SSH paths remain
available for recovery. The desktop is intentionally minimal: a quiet
background, a compact bottom bar with `Menu`, `Term`, `Files`, task list, and
clock, plus organized menus for everything else.

- Graphical apps: Dillo (browser), PCManFM (files), Leafpad (editor), Geany
  (code), plus terminal tools (`links`, `nano`, `mc`) under `Apps`
- `Menu > Network`: WiFi setup, status, interfaces, external scan
- `Menu > Brightness`: LCD brightness (also `x-chip-brightness` in a terminal)
- `Menu > Pocket`: battery/keyboard/audio status, time, logs, system update
- `Menu > Window`: process monitor, close apps, restart the UI
- The root menu opens on right-click/touch button 3 only, and there are no
  direct power-off entries in the menu, so a stray tap cannot kill the session

UI defaults use `Luxi Sans 9` and `Luxi Mono 9` so apps fit the `480x272` LCD.
JWM uses a small local XPM icon set (`/usr/local/share/x-chip/xorg/icons`),
GTK apps use the matching `x-chip` icon theme, and the default wallpaper is
`/usr/local/share/x-chip/xorg/wallpapers/pocket-core.png`.

Manual desktop control:

```sh
x-chip-desktop-start                       # start or restart the desktop
X_CHIP_DESKTOP_WM=flwm x-chip-desktop-start # use flwm instead of JWM
```

Autostart defaults live in `/usr/local/etc/x-chip/desktop.conf`; set
`X_CHIP_DESKTOP_AUTOSTART=0` there to boot to console only.

Touchscreen calibration is one plain text matrix file:

```text
/usr/local/share/x-chip/xorg/touchscreen-calibration.matrix
```

To recalibrate (five positions, three taps each, saved and reapplied):

```sh
DISPLAY=:0 x-chip-touch-calibrate
```

Xorg/session logs land in `/tmp/x-chip-startx.log`, `/tmp/Xorg.0.log`, and
`/var/log/x-chip-desktop.log`. The active Xorg config is
`/usr/local/etc/X11/xorg.conf.d/20-pocketchip-fbdev.conf`. The fbturbo driver
is not loaded by default (the available module targets an older Xorg video
ABI); a sample config for experiments is kept at
`/usr/local/share/x-chip/xorg/20-pocketchip-fbturbo.conf.example`.

## 6. Games and Music

When the community app pack is present in the image (it is, in public
releases), JWM exposes music tools under `Music` and games under `Games`. Apps
load on first click, not at boot, so the base system stays fast.

- Music: SunVox, PixiTracker, PixiTracker 1Bit, Pixilang, GoatTracker
- Games: Doom (Chocolate Doom + Freedoom Phase 1), TIC-80 fantasy console,
  Game Boy / Color / Advance via mGBA, PICO-8 launcher (bring your own
  licensed PICO-8 binary)

No copyrighted game content is bundled. TIC-80 carts download from `tic80.com`
on first launch; mGBA downloads verified free homebrew (`2048`, `uCity`); your
own legal `.gb`/`.gbc`/`.gba` files work from `~/Games/GameBoy` or
`~/Downloads`. For PICO-8, install your licensed Linux ARM files under
`~/pico-8/pico8` or set `X_CHIP_PICO8_BIN`.

PocketCHIP game controls (TIC-80 and mGBA):

- Arrow keys = direction
- `1` = A, `2` = B
- `Enter` = Start, `Backspace` = Select
- The PocketCHIP Home/Power key closes running games

Doom uses the Chocolate Doom keyboard defaults: arrows to move and turn,
`Right Ctrl` fire, `Space` use, `Right Shift` run, `Right Alt` strafe,
`1`-`8` weapons, `Tab` automap, `Esc` menu. Doom starts with silent audio on
PocketCHIP because SDL audio can block startup; set `X_CHIP_DOOM_SOUND=1` to
test audio.

## Build It Yourself

Everything below is for people rebuilding the image from source. Normal users
never need it.

### Personal image (your WiFi, your SSH key)

```sh
make deps
cp secrets.env.example secrets.env
$EDITOR secrets.env
make container-build
make verify
make flash-local            # or: FLASH_HOST=my-linux-host make flash-host
```

`make deps` clones the sibling board-data repos (`chip-debroot`,
`x-chip-tools`). The rootfs assembler must preserve root-owned files and
setuid bits, so use the container path (or `fakeroot` for local experiments).
Never publish a personal image: it contains your WiFi credentials and SSH key,
and `scripts/08-package-release.sh` refuses to package one unless
`ALLOW_PERSONAL_RELEASE=1`.

### Public image and release

```sh
make deps
make public-release
```

`public-release` rebuilds the public rootfs (no WiFi config, empty
`authorized_keys`, password SSH for `chip`), runs the full verifier, then
writes everything to `dist/`: the flashable rootfs, the `x-chip-update` pack,
their `.sha256` files, and a MANIFEST. Upload the `dist/` files unrenamed to a
GitHub release marked "Latest"; the flasher and the on-device updater find it
automatically. See `docs/RELEASE.md` for the checklist.

Override the default public password at build time with
`SSH_PASSWORD='...' make public-rootfs`.

### Community app pack

```sh
make community-tcz                            # all apps
./scripts/09-build-community-tcz.sh doom      # or one at a time
```

Outputs go to `dist/community-tcz/`; if that directory exists when the rootfs
is assembled, the apps and their dependencies are cached into `/tce/optional`.
Sources are pinned: git recipes by commit (TIC-80 `v1.1.2837`, mGBA `0.10.5`,
Chocolate Doom `3.1.1`), binary releases by SHA256 (WarmPlace apps, Freedoom
`0.13.0`), GoatTracker from Debian source. Virtual ANS builds with the manual
recipe but needs OpenGL, which the PocketCHIP fbdev stack does not provide.

For a private image only, legal local ROMs can be baked in with
`make private-gameboy-rootfs` (see `PRIVATE_ROMS_DIR`); this is rejected for
public images and caught by release verification.

## Hardware Support

- Both PocketCHIP keyboard revisions are supported: the boot script reads the
  DIP EEPROM product version and applies the right key matrix (v72 or v73), so
  Shift and Esc land on the correct keys on either hardware
- VGA DIP, HDMI DIP, and the Source Parts Popcorn/Stove HDMI DIP are
  auto-detected the same way; with no readable EEPROM the PocketCHIP overlay
  is applied as a safe default
- Internal WiFi: RTL8723BS (client/default-route role); an optional RTL8812AU
  USB adapter is used for external scans when plugged in
  (`/usr/local/etc/x-chip/wifi.conf` configures the roles)
- No RTC battery: the clock is floored to the image build date at every boot
  and synced over NTP after WiFi connects, so HTTPS always works
- Audio, backlight, battery status, touchscreen, and the Fn key layer are
  configured out of the box; `x-chip-keyboard-status`, `x-chip-audio-status`,
  and `x-chip-power-status` report the details

The PocketCHIP keymap is a partial `loadkeys` overlay merged with the kernel
default console map at build time, and the matching Fn layer is applied in
Xorg with `x-chip-x-keymap`, so Fn shortcuts work on the console and in JWM.

## Reference

### Important files

```text
config.env                     build defaults (kernel, pins, identity)
config/                        wallpaper, icons, touchscreen calibration
boot/boot.cmd                  U-Boot NAND boot script (DIP overlay select)
kernel/sun5i-chip.config       PocketCHIP kernel config fragment
kernel/dip-9d011a-1-48.dts     PocketCHIP v72 keyboard overlay
tce/onboot.lst                 extensions loaded at boot
tce/xorg.lst                   desktop extensions loaded by desktop startup
scripts/00-fetch-deps.sh       fetch chip-debroot and x-chip-tools
scripts/03-assemble-rootfs.sh  rootfs assembly (installs all x-chip tools)
scripts/07-verify-rootfs.sh    image verification gate
scripts/08-package-release.sh  release packaging (rootfs + update pack)
scripts/10-build-update-pack.sh update pack builder
scripts/flash-release-pocketchip.sh  community flasher
```

### Defaults

- Hostname `chip`, user `chip`, LCD brightness `6`
- Config files under `/usr/local/etc/x-chip/`: `display.conf`,
  `desktop.conf`, `desktop-stats.conf`, `wifi.conf`
- On-device release identity: `/usr/local/share/x-chip/release-info`; the
  last applied update is tracked in
  `/usr/local/share/x-chip/applied-release`
- Media pack (`ffmpeg`, `mpg123`) is preseeded but loads on demand via
  `x-chip-media-on`, not at boot
- Build pins live in `config.env`: TinyCore base SHA256, kernel tarball
  SHA256, and the `x-chip-tools`/U-Boot/OS release tags and SHA256s used by
  the flasher

### Secrets and publishing

The git repository contains only source, scripts, docs, and public defaults.
`secrets.env`, build trees, generated rootfs archives, and private keys are
ignored by `.gitignore`. Personal images can contain
`/etc/wpa_supplicant.conf`, `authorized_keys`, and SSH host keys: never
publish them. Follow `docs/RELEASE.md` for public releases.

### Manual commands

```sh
echo 6 | sudo tee /sys/class/backlight/backlight/brightness   # LCD brightness
x-chip-keyboard-status                                        # board status
x-chip-audio-status
x-chip-power-status
./scripts/05-flash-local.sh --rootfs FILE.rootfs.tar.gz --flash  # flash a local tar
```

`x-chip-brightness` clamps brightness to a minimum of `1`, so the tray buttons
cannot black out the LCD.
