# Reproducible cross-build environment for x-chip-tinycore.
# Builds the sun5i kernel and assembles the rootfs tar; no device access needed.
FROM debian:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
        make gcc git kbd bc bison flex openssl libssl-dev libncurses-dev \
        crossbuild-essential-armhf u-boot-tools kmod fakeroot \
        cpio gzip xz-utils unzip curl ca-certificates patch cpp mtools fdisk \
        squashfs-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
