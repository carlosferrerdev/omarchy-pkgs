# ==============================================================================
# Gomarchy Package Builder - Multi-Architecture
# Supports: x86_64 (Arch Linux) and aarch64 (Arch Linux ARM)
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Bootstrap - Create base Arch/ALARM system from scratch
# ------------------------------------------------------------------------------
FROM docker.io/library/alpine:3.21.7@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d AS bootstrapper

ARG TARGETARCH
ARG BUILDPLATFORM

COPY pacstrap-docker /usr/local/bin/

RUN apk add --no-cache \
    pacman-makepkg \
    curl \
    bash \
    zstd \
    gnupg

# Map Docker TARGETARCH (amd64/arm64) to Arch naming (x86_64/aarch64)
# Create pacman.conf from scratch so we control it entirely
RUN mkdir -p /etc/pacman.d && \
    case "${TARGETARCH}" in \
    amd64) \
        echo "x86_64" > /tmp/arch && \
        REPOS="[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n" ;; \
    arm64) \
        echo "aarch64" > /tmp/arch && \
        REPOS="[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n\n[alarm]\nInclude = /etc/pacman.d/mirrorlist\n\n[aur]\nInclude = /etc/pacman.d/mirrorlist\n" ;; \
    *) \
        echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    printf '[options]\nHoldPkg = pacman glibc\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\n\n%b' "$REPOS" > /etc/pacman.conf

RUN if [ "${TARGETARCH}" = "amd64" ]; then \
        printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > /etc/pacman.d/mirrorlist; \
    else \
        ALARM_PKGBUILDS_COMMIT="c9df006bd10533df2d59a94cc0c565897cf945b6" && \
        ALARM_MIRRORLIST_SHA256="e25f0bc284287342b221377d2a0ca0203eaf13f52d369d6676c4730a8e2b1de1" && \
        ALARM_MIRRORLIST="/tmp/archlinuxarm-mirrorlist" && \
        curl -fsSL \
            "https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/${ALARM_PKGBUILDS_COMMIT}/core/pacman-mirrorlist/mirrorlist" \
            -o "${ALARM_MIRRORLIST}" && \
        printf '%s  %s\n' "${ALARM_MIRRORLIST_SHA256}" "${ALARM_MIRRORLIST}" | sha256sum -c - && \
        sed -E 's/^\s*#\s*Server\s*=/Server =/g' "${ALARM_MIRRORLIST}" > /etc/pacman.d/mirrorlist && \
        sed -i 's/\$arch/aarch64/g' /etc/pacman.d/mirrorlist; \
    fi

# Bootstrap keyrings (required before pacstrap can verify packages)
RUN mkdir -p /usr/share/pacman/keyrings && \
    if [ "${TARGETARCH}" = "arm64" ]; then \
        ALARM_PKGBUILDS_COMMIT="c9df006bd10533df2d59a94cc0c565897cf945b6" && \
        KEYRING_URL="https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/${ALARM_PKGBUILDS_COMMIT}/core/archlinuxarm-keyring" && \
        curl -fsSL "${KEYRING_URL}/archlinuxarm-revoked" -o /usr/share/pacman/keyrings/archlinuxarm-revoked && \
        printf '%s  %s\n' \
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
            "/usr/share/pacman/keyrings/archlinuxarm-revoked" | sha256sum -c - && \
        curl -fsSL "${KEYRING_URL}/archlinuxarm-trusted" -o /usr/share/pacman/keyrings/archlinuxarm-trusted && \
        printf '%s  %s\n' \
            "f2a7250f2a2b77542f82f4219b2bae7895f27b3dcfdf350b497e2be306af776d" \
            "/usr/share/pacman/keyrings/archlinuxarm-trusted" | sha256sum -c - && \
        curl -fsSL "${KEYRING_URL}/archlinuxarm.gpg" -o /usr/share/pacman/keyrings/archlinuxarm.gpg && \
        printf '%s  %s\n' \
            "6ce771e853f04a38a5b533cb33e61f877b9b06b58b6db051eb8a15d737a2332f" \
            "/usr/share/pacman/keyrings/archlinuxarm.gpg" | sha256sum -c - && \
        BOOTSTRAP_EXTRA="archlinuxarm-keyring"; \
    else \
        mkdir /tmp/archlinux-keyring && \
        ARCH_KEYRING_PACKAGE="/tmp/archlinux-keyring-20260727-1-any.pkg.tar.zst" && \
        curl -fsSL \
            "https://archive.archlinux.org/packages/a/archlinux-keyring/archlinux-keyring-20260727-1-any.pkg.tar.zst" \
            -o "${ARCH_KEYRING_PACKAGE}" && \
        printf '%s  %s\n' \
            "694c4236ff403b5be549436d2df2910092cb6d778bb027fd232be9dddf4ea090" \
            "${ARCH_KEYRING_PACKAGE}" | sha256sum -c - && \
        unzstd < "${ARCH_KEYRING_PACKAGE}" | tar -C /tmp/archlinux-keyring -xv && \
        mv /tmp/archlinux-keyring/usr/share/pacman/keyrings/* /usr/share/pacman/keyrings/ && \
        BOOTSTRAP_EXTRA=""; \
    fi && \
    pacman-key --init && \
    pacman-key --populate

RUN mkdir /rootfs && \
    if [ "${TARGETARCH}" = "arm64" ]; then \
        BOOTSTRAP_EXTRA="archlinuxarm-keyring"; \
    else \
        BOOTSTRAP_EXTRA=""; \
    fi && \
    pacstrap-docker /rootfs base ${BOOTSTRAP_EXTRA} && \
    cp /etc/pacman.conf /rootfs/etc/pacman.conf && \
    cp /etc/pacman.d/mirrorlist /rootfs/etc/pacman.d/mirrorlist && \
    echo "en_US.UTF-8 UTF-8" > /rootfs/etc/locale.gen && \
    echo "LANG=en_US.UTF-8" > /rootfs/etc/locale.conf && \
    rm -rf /rootfs/var/lib/pacman/sync/* \
           /rootfs/var/cache/pacman/pkg/* \
           /rootfs/tmp/*

# ------------------------------------------------------------------------------
# Stage 2: Build Environment
# ------------------------------------------------------------------------------
FROM scratch AS builder

ARG TARGETARCH

COPY --from=bootstrapper /rootfs/ /

ENV LANG=en_US.UTF-8
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN ln -sf /usr/lib/os-release /etc/os-release && \
    locale-gen && \
    pacman-key --init && \
    if pacman -Q archlinuxarm-keyring >/dev/null 2>&1; then \
        pacman-key --populate archlinux archlinuxarm && \
        pacman-key --lsign-key 77193F152BDBE6A6; \
    else \
        pacman-key --populate archlinux; \
    fi

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        base-devel \
        git \
        sudo \
        wget \
        curl \
        jq \
        gnupg && \
    pacman -Scc --noconfirm && \
    rm -rf /var/cache/pacman/pkg/*

# makepkg cannot run as root. Match the invoking non-root host UID when one is
# available; repository hosts run as root and deliberately use the unprivileged
# default 1000 instead.
ARG BUILDER_UID=1000
RUN groupadd -g "${BUILDER_UID}" builder && \
    useradd -m -u "${BUILDER_UID}" -g builder -G wheel -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /home/builder/.gnupg /build-output && \
    chmod 700 /home/builder/.gnupg && \
    chown -R builder:builder /home/builder /build-output

RUN sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf && \
    sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -z -q --threads=0 -)/' /etc/makepkg.conf

# Pacman wrapper that auto-resolves package conflicts (e.g. rustup vs rust).
# makepkg only passes --noconfirm to pacman, which defaults to 'N' on conflict
# prompts. --ask 4 tells pacman to answer 'yes' to replacement prompts instead.
RUN printf '#!/bin/bash\nexec /usr/bin/pacman --ask 4 "$@"\n' > /usr/local/bin/pacman-for-makepkg && \
    chmod +x /usr/local/bin/pacman-for-makepkg

RUN rm -rf /etc/pacman.d/gnupg/{openpgp-revocs.d/,private-keys-v1.d/,pubring.gpg~,gnupg.S.}*

USER builder
WORKDIR /src

CMD ["/bin/bash"]

LABEL maintainer="Gomarchy contributors"
LABEL description="Gomarchy multi-architecture Arch Linux package build environment"
LABEL version="2.0"
LABEL architectures="x86_64,aarch64"
