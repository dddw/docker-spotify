ARG           FROM_REGISTRY=index.docker.io/dubodubonduponey

ARG           FROM_IMAGE_FETCHER=base:golang-bullseye-2022-06-01@sha256:7780f88fc0da1a5fd87f91cbb229e6932fc1fc2993f9c2d04210f6b909b93172
ARG           FROM_IMAGE_BUILDER=base:builder-bullseye-2022-06-01@sha256:3fe68fe3e3eb1c295bd5213cc4a296e929ab59c139ba1a55a04f716c352229ee
ARG           FROM_IMAGE_AUDITOR=base:auditor-bullseye-2022-06-01@sha256:a2f2097b9b24c3650e149acb25719f72e56b01df139f120fc1f783d46260a8ce
ARG           FROM_IMAGE_TOOLS=tools:linux-bullseye-2022-05-01@sha256:6268013e3bd16eaaf7dd15c7689f8740bd00af1149c92795cc42fab4f3c6d07a
ARG           FROM_IMAGE_RUNTIME=base:runtime-bullseye-2022-06-01@sha256:fe875fbfa104beb7afbcfafe3d8ab9b3640c7d25a0ea285a76bf3d71ca216300

FROM          $FROM_REGISTRY/$FROM_IMAGE_TOOLS                                                                          AS builder-tools

#######################
# Fetcher
#######################
FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_FETCHER                                              AS fetcher-main

ARG           GIT_REPO=github.com/librespot-org/librespot
ARG           GIT_VERSION=v0.4.2
ARG           GIT_COMMIT=22f8aed3fc8c710761c79b3d14dd14c135c46de7

RUN           git clone --recurse-submodules https://"$GIT_REPO" .; git checkout "$GIT_COMMIT"

#######################
# Main builder
#######################
FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_BUILDER                                              AS builder-main

ARG           TARGETARCH
ARG           TARGETOS
ARG           TARGETVARIANT

COPY          --from=fetcher-main /source /source

# hadolint ignore=DL3009
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
              apt-get update -qq; \
              apt-get install -qq --no-install-recommends \
                libpulse-dev:"$DEB_TARGET_ARCH"=14.2-2 \
                libasound2-dev:"$DEB_TARGET_ARCH"=1.2.4-1.1

# Maybe consider https://github.com/japaric/rust-cross for cross-compilation

RUN           mkdir -p /dist/boot/bin/

ENV           RUST_VERSION=1.53.0
#RUN           case "$TARGETPLATFORM" in \
#                "linux/amd64")    arch=x86_64;      abi=gnu;        ga=x86_64;      ;; \
#                "linux/arm64")    arch=aarch64;     abi=gnu;        ga=aarch64;     ;; \
#                "linux/arm/v7")   arch=armv7;       abi=gnueabihf;  ga=arm;         ;; \ # DEB_TARGET_GNU_SYSTEM=linux-gnueabihf GA=$DEB_TARGET_GNU_CPU
#                "linux/ppc64le")  arch=powerpc64le; abi=gnu;        ga=powerpc64le; ;; \ # GA=$DEB_TARGET_GNU_CPU
#                "linux/s390x")    arch=s390x;       abi=gnu;        ga=s390x;       ;; \
#              esac; \
#              printf "%s\n%s\n" "[target.${arch}-unknown-linux-${abi}]" "linker = \"${ga}-linux-${abi}-gcc\"" >> "$HOME/.cargo/config"; \
#              PATH="$PATH:$HOME/.cargo/bin" rustup target add "${arch}-unknown-linux-${abi}"

# XXX pin rust to install 1.48.0
RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=CERTIFICATE \
              --mount=type=secret,id=KEY \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=.curlrc \
              curl -sSf https://sh.rustup.rs | sh -s -- -y

# XXX this is using curl under the hood
# Somehow, not passing secrets along seems to fuck things up because of
# SSL_CERT_FILE <- this is bad if true
RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=CERTIFICATE \
              --mount=type=secret,id=KEY \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=.curlrc \
              eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
              export PKG_CONFIG_ALLOW_CROSS=1; \
              export PKG_CONFIG="${DEB_TARGET_GNU_TYPE}-pkg-config"; \
              export PATH="$PATH:$HOME/.cargo/bin"; \
              printf "%s\n%s\n" "[target.$DEB_TARGET_GNU_CPU-unknown-$DEB_TARGET_GNU_SYSTEM]" "linker = \"$DEB_TARGET_GNU_TYPE-gcc\"" >> "$HOME/.cargo/config"; \
              rustup toolchain install "$RUST_VERSION"; \
              rustup target add "$DEB_TARGET_GNU_CPU-unknown-$DEB_TARGET_GNU_SYSTEM"; \
              cargo build --locked --target="$DEB_TARGET_GNU_CPU-unknown-$DEB_TARGET_GNU_SYSTEM" --release --no-default-features --features "alsa-backend,pulseaudio-backend"; \
              cp ./target/"$DEB_TARGET_GNU_CPU-unknown-$DEB_TARGET_GNU_SYSTEM"/release/librespot /dist/boot/bin/

#######################
# Builder assembly
#######################
FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_AUDITOR                                              AS assembly

ARG           TARGETARCH
ARG           TARGETVARIANT

# This should not be necessary and linked statically...
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
              apt-get update -qq && \
              apt-get install -qq --no-install-recommends \
                fbi:"$DEB_TARGET_ARCH"=2.10-4 \
              && apt-get -qq autoremove       \
              && apt-get -qq clean            \
              && rm -rf /var/lib/apt/lists/*  \
              && rm -rf /tmp/*                \
              && rm -rf /var/tmp/*

COPY          --from=builder-main   /dist/boot           /dist/boot

RUN           cp "$(which fbi)" /dist/boot/bin
RUN           setcap 'cap_sys_tty_config+ep' /dist/boot/bin/fbi

# What about TLS?
#COPY          --from=builder-tools  /boot/bin/caddy          /dist/boot/bin
COPY          --from=builder-tools  /boot/bin/http-health    /dist/boot/bin
COPY          --from=builder-tools  /boot/bin/goello-server-ng /dist/boot/bin

RUN           RUNNING=true \
              STATIC=true \
                dubo-check validate /dist/boot/bin/http-health

#RUN           [ "$TARGETARCH" != "amd64" ] || export STACK_CLASH=true; \
#              STATIC=true \
#              FORTIFIED=true \
#              STACK_PROTECTED=true \

# XXX missing libpulse-simple.so.0 - why are they dynamic?
#RUN           RUNNING=true \
#              NO_SYSTEM_LINK=true \
RUN           BIND_NOW=true \
              PIE=true \
              RO_RELOCATIONS=true \
                dubo-check validate /dist/boot/bin/librespot

# RUN           setcap 'cap_net_bind_service+ep' /dist/boot/bin/librespot

RUN           chmod 555 /dist/boot/bin/*; \
              epoch="$(date --date "$BUILD_CREATED" +%s)"; \
              find /dist/boot -newermt "@$epoch" -exec touch --no-dereference --date="@$epoch" '{}' +;


#######################
# Running image
#######################
FROM          $FROM_REGISTRY/$FROM_IMAGE_RUNTIME

USER          root

# This should not be necessary and linked statically...
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              apt-get update -qq && \
              apt-get install -qq --no-install-recommends \
                libasound2=1.2.4-1.1 \
                libpulse0=14.2-2 \
                curl=7.74.0-1.3+deb11u1 \
                fbi=2.10-4 \
                jq=1.6-2.1 \
              && apt-get -qq autoremove       \
              && apt-get -qq clean            \
              && rm -rf /var/lib/apt/lists/*  \
              && rm -rf /tmp/*                \
              && rm -rf /var/tmp/*

USER          dubo-dubon-duponey

# Disable by default as that prevents the zeroconf server to be started by librespot unfortunately...
ENV           _SERVICE_NICK=""
ENV           _SERVICE_TYPE="spotify-connect"

COPY          --from=assembly --chown=$BUILD_UID:root /dist /

### mDNS broadcasting
# Whether to enable MDNS broadcasting or not
ENV           MDNS_ENABLED=true
# Type to advertise
ENV           MDNS_TYPE="_$_SERVICE_TYPE._tcp"
# Name is used as a short description for the service
ENV           MDNS_NAME="$_SERVICE_NICK mDNS display name"
# The service will be annonced and reachable at $MDNS_HOST.local (set to empty string to disable mDNS announces entirely)
ENV           MDNS_HOST="$_SERVICE_NICK"
# Also announce the service as a workstation (for example for the benefit of coreDNS mDNS)
ENV           MDNS_STATION=true


ENV           LOG_LEVEL="warn"
ENV           PORT=10042
# Will default to whatever is the system default
ENV           DEVICE=""
# (alsa|pulseaudio|pipe|process)
ENV           OUTPUT=alsa

ENV           HEALTHCHECK_URL="http://127.0.0.1:$PORT/?action=getInfo"
# Set to true to have librespot display coverart on your RPI framebuffer (/dev/fb0 and /dev/tty1 need to be mounted and CAP added)
ENV           DISPLAY_ENABLED=false
ENV           SPOTIFY_CLIENT_ID=""
ENV           SPOTIFY_CLIENT_SECRET=""

EXPOSE        $PORT/tcp

VOLUME        /tmp

HEALTHCHECK   --interval=120s --timeout=30s --start-period=10s --retries=1 CMD http-health || exit 1
