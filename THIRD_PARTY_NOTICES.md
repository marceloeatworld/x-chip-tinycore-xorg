# Third-Party Notices

This repository contains build glue, configuration, and documentation for a
PocketCHIP TinyCore image. The generated rootfs image is a combined software
distribution and carries the licenses of the components included in that image.

## Not Vendored In Git

The build downloads or consumes these external components:

- Linux kernel source from `kernel.org`.
  License: GPL-2.0-only, as provided by the upstream Linux kernel source tree.
- TinyCore/piCore armhf base image and `.tcz` extensions from
  `tinycorelinux.net`.
  License: see the individual TinyCore base and extension metadata.
- `aircrack-ng/rtl8812au` for the optional RTL8812AU USB WiFi module.
  License: GPL-2.0, as provided by that upstream source tree.
- `macromorgan/chip-debroot` board patches and device-tree overlay sources.
  This repo uses it as an external source of CHIP/PocketCHIP board data.
- `nextthingco/x-chip-tools` for FEL/U-Boot/NAND flashing support.
  This repo uses it as an external flasher; it is not bundled here.

Optional community `.tcz` extras are built only when requested with
`scripts/09-build-community-tcz.sh`:

- TIC-80 from `https://github.com/nesbox/TIC-80`.
  License: MIT, as provided by the upstream source tree.
- GoatTracker from Debian source package `goattracker`.
  Upstream: `https://cadaver.github.io/tools.html`.
  License: GPL-2-or-later, as provided by the Debian source package.
- mGBA from `https://github.com/mgba-emu/mgba`.
  License: MPL-2.0, as provided by the upstream source tree.
- Chocolate Doom from `https://github.com/chocolate-doom/chocolate-doom`.
  License: GPL-2-or-later, as provided by the upstream source tree.
- Freedoom from `https://freedoom.github.io/`.
  License: BSD-3-Clause-style terms, as provided in `COPYING.txt` in the
  Freedoom release archive.

The TIC-80 game menu ships only a small manifest of public `tic80.com` cart
URLs. Cartridge files are not vendored in this repository and should not be
redistributed in public release assets without permission from the cartridge
authors.

Game Boy, Game Boy Color, and Game Boy Advance ROM files are not bundled and
must not be redistributed in public release assets unless the distributor has
the rights to do so. Commercial Doom WAD files are not bundled either; the Doom
launcher uses the free Freedoom Phase 1 IWAD from `doom.tcz`.

## Firmware

The image may include Realtek RTL8723BS firmware. For private builds this can be
copied from a local known-good Debian rootfs. For public builds the assembler can
extract the same firmware from TinyCore's `firmware-rtlwifi.tcz` extension.

Firmware redistribution terms are controlled by the upstream firmware package,
not by this repository's MIT license.

## Repository License Scope

The `LICENSE` file applies to this repository's original scripts,
configuration, and documentation only. It does not relicense the Linux kernel,
TinyCore extensions, firmware, third-party kernel patches, or generated binary
rootfs images.
