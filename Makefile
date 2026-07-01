SHELL := /bin/bash
PRIVATE_ROMS_DIR ?= dist/private-roms/GameBoy

.PHONY: all deps base kernel rtl8812au rootfs container-build private-gameboy-rootfs public-rootfs verify public-verify public-release community-tcz update-pack flash-local-check flash-local flash-host-check flash-host flash-pi-check flash-pi clean distclean

all: rootfs

deps:
	./scripts/00-fetch-deps.sh

# CorePure armhf base -> build/rootfs
base:
	./scripts/01-fetch-base.sh

# sun5i-optimized kernel -> build/rootfs/{boot,lib/modules}
kernel: base
	./scripts/02-build-kernel.sh

rtl8812au: kernel
	./scripts/04-build-rtl8812au.sh

# finishing (boot.scr, ssh, tce) + pack -> $(OUT)
rootfs: rtl8812au
	./scripts/03-assemble-rootfs.sh

container-build:
	./scripts/06-build-in-container.sh

private-gameboy-rootfs:
	@if [ ! -d "$(PRIVATE_ROMS_DIR)" ]; then \
		echo "ERROR: private ROM directory does not exist: $(PRIVATE_ROMS_DIR)" >&2; \
		echo "Put legal .gb/.gbc/.gba files there, or override PRIVATE_ROMS_DIR=..." >&2; \
		exit 1; \
	fi
	@if ! find "$(PRIVATE_ROMS_DIR)" -maxdepth 1 -type f \( -iname '*.gb' -o -iname '*.gbc' -o -iname '*.gba' \) -print -quit | grep -q .; then \
		echo "ERROR: no .gb/.gbc/.gba files found in $(PRIVATE_ROMS_DIR)" >&2; \
		exit 1; \
	fi
	@if [ ! -f dist/community-tcz/mgba.tcz ]; then \
		echo "WARN: dist/community-tcz/mgba.tcz is missing; run 'make community-tcz' if you want the image to include the mGBA emulator cache." >&2; \
	fi
	INCLUDE_PRIVATE_ROMS=1 PRIVATE_ROMS_DIR="$(PRIVATE_ROMS_DIR)" ./scripts/06-build-in-container.sh

public-rootfs:
	PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 SECRETS_ENV=/dev/null ./scripts/06-build-in-container.sh

verify:
	./scripts/07-verify-rootfs.sh

public-verify:
	PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 SECRETS_ENV=/dev/null ./scripts/07-verify-rootfs.sh

# Rebuild first so the packaged tarball always matches the git rev stamped in
# MANIFEST.txt; 08 would otherwise happily package a stale xorg-rootfs.tar.gz.
public-release: public-rootfs
	PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 SECRETS_ENV=/dev/null ./scripts/08-package-release.sh

community-tcz:
	./scripts/09-build-community-tcz.sh

update-pack:
	./scripts/10-build-update-pack.sh

flash-local-check: verify
	./scripts/05-flash-local.sh

flash-local: verify
	./scripts/05-flash-local.sh --flash

flash-host-check: verify
	./scripts/05-flash-via-host.sh

flash-host: verify
	./scripts/05-flash-via-host.sh --flash

flash-pi-check: verify
	FLASH_HOST=$${FLASH_HOST:-$${PI_HOST:-pi}} ./scripts/05-flash-via-host.sh

flash-pi: verify
	FLASH_HOST=$${FLASH_HOST:-$${PI_HOST:-pi}} ./scripts/05-flash-via-host.sh --flash

clean:
	rm -rf build/rootfs *-rootfs.tar.gz

distclean: clean
	rm -rf build
