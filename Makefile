SHELL := /bin/bash
.PHONY: all deps base kernel rtl8812au rootfs container-build public-rootfs verify public-verify public-release flash-local-check flash-local flash-host-check flash-host flash-pi-check flash-pi clean distclean

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

public-rootfs:
	PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 SECRETS_ENV=/dev/null ./scripts/06-build-in-container.sh

verify:
	./scripts/07-verify-rootfs.sh

public-verify:
	PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 SECRETS_ENV=/dev/null ./scripts/07-verify-rootfs.sh

public-release:
	PUBLIC_IMAGE=1 REQUIRE_WIFI_CONFIG=0 REQUIRE_AUTHORIZED_KEYS=0 SECRETS_ENV=/dev/null ./scripts/08-package-release.sh

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
