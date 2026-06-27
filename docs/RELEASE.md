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

## Private Override

Only for a private backup:

```sh
ALLOW_PERSONAL_RELEASE=1 ./scripts/08-package-release.sh
```

Never upload that output to a public repo or public release.
