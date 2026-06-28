# Release Checklist

## Public Git Repo

Commit source only:

- `Dockerfile`
- `Makefile`
- `README.md`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
- `config.env`
- `config/`
- `secrets.env.example`
- `boot/`
- `kernel/`
- `scripts/`
- `tce/`
- `docs/`

Do not commit:

- `secrets.env`
- `build/`
- `xorg-rootfs.tar.gz`
- `dist/`
- downloaded images or archives
- private keys or certificates
- logs and local tool outputs

## Personal Image

For your own device:

```sh
cp secrets.env.example secrets.env
$EDITOR secrets.env
make container-build
make verify
make flash-local
```

Do not upload this image publicly. It can contain WiFi config and SSH keys.

## Public Image

For a GitHub Release:

```sh
make distclean
make deps
make public-rootfs
make public-verify
make public-release
```

The public build path sets `PUBLIC_IMAGE=1`. That forces empty
`authorized_keys`, removes WiFi config, and enables password SSH for the default
`chip` account.

Upload files from `dist/`.

Before uploading, check:

```sh
cat dist/*/MANIFEST.txt
```

Public release must show:

```text
contains_wifi_config=0
authorized_keys_bytes=0
public_image=1
ssh_user=chip
ssh_password_auth=yes
```

The public SSH login is `chip` / `chip` by default. Override the password for a
custom public build with `SSH_PASSWORD=... make public-rootfs`.

## Optional Community `.tcz` Extras

The base public image should stay lightweight. Build optional apps separately:

```sh
make community-tcz
```

The output goes to `dist/community-tcz/`. If that directory exists during rootfs
assembly, `tic80.tcz`, `goattracker.tcz`, `mgba.tcz`, `doom.tcz`, and their
dependencies are cached in `/tce/optional` for click-to-load use from the JWM
`Games` menu. Do not add these extensions to the boot lists unless you
intentionally want a larger and slower boot.

Current extras:

- `goattracker.tcz`, GPL-2-or-later, built from Debian source
- `tic80.tcz`, MIT, built from upstream TIC-80 source
- `mgba.tcz`, MPL-2.0, built from upstream mGBA source
- `doom.tcz`, GPL-2-or-later Chocolate Doom plus BSD-3-Clause Freedoom assets
- `x-chip-pico8`, launcher only; PICO-8 itself is commercial and not bundled

Do not upload bundled TIC-80 cartridge files in a public release unless each
game has explicit redistribution permission. The default image only ships a
manifest of `tic80.com` URLs; carts are downloaded by the user on first launch.
Do not upload ROM files, commercial Doom WAD files, or PICO-8 binaries with the
public release. Freedoom Phase 1 in `doom.tcz` is free content and can be
included with its license and credits.

For a private image, local legal Game Boy ROMs can be included with:

```sh
INCLUDE_PRIVATE_ROMS=1 PRIVATE_ROMS_DIR=dist/private-roms/GameBoy make rootfs
```

The public path rejects `INCLUDE_PRIVATE_ROMS=1`, and `public-verify` fails if a
`.gb`, `.gbc`, or `.gba` file is present under `~/Games/GameBoy`.

## Private Override

Only for a private backup:

```sh
ALLOW_PERSONAL_RELEASE=1 ./scripts/08-package-release.sh
```

Never upload that output to a public repo or public release.
