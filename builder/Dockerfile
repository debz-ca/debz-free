FROM debian:trixie-slim

# ---------------------------------------------------------------------------
# Debz live-build builder image
# Base: Debian 13 (trixie-slim)
# Purpose: Provides the live-build toolchain for building the Debz ISO.
#          ZFS packages and zfsbootmenu are installed INTO the ISO chroot
#          by live-build hooks and package lists — NOT here in the builder.
# ---------------------------------------------------------------------------

ENV DEBIAN_FRONTEND=noninteractive

# The trixie-slim base image uses DEB822 format at /etc/apt/sources.list.d/debian.sources.
# Replace it with a plain .list file that adds contrib + non-free + non-free-firmware.
# HTTP is required here — trixie-slim ships without ca-certificates, so HTTPS
# would fail before we can install them. The live-build chroot uses HTTPS once
# ca-certificates is available on the installed system.
RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources && \
    echo "deb http://mirror.it.ubc.ca/debian trixie main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list.d/debz-build.list && \
    echo "deb http://mirror.it.ubc.ca/debian trixie-updates main contrib non-free non-free-firmware" \
        >> /etc/apt/sources.list.d/debz-build.list && \
    echo "deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware" \
        >> /etc/apt/sources.list.d/debz-build.list

# Install live-build toolchain and ISO construction tools.
# ZFS packages (zfs-dkms, zfsutils-linux, zfsbootmenu) are NOT installed here —
# they are installed into the ISO chroot via live-build package lists and hooks.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-utils \
        binfmt-support \
        build-essential \
        ca-certificates \
        curl \
        debootstrap \
        dpkg-dev \
        dosfstools \
        gdisk \
        git \
        gnupg2 \
        grub-efi-amd64 \
        grub-efi-amd64-signed \
        jq \
        live-build \
        mtools \
        parted \
        python3 \
        python3-yaml \
        qemu-user-static \
        qemu-utils \
        rsync \
        shellcheck \
        shim-signed \
        squashfs-tools \
        wget \
        xorriso \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ENTRYPOINT ["/build/builder/build-iso.sh"]
