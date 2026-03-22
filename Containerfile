FROM docker.io/library/archlinux:latest AS aurbuilder

ARG INCLUDE_AUR_PACKAGES=""

RUN <<EOR
set -euxo pipefail

pacman -Syu --noconfirm
pacman -S --noconfirm base-devel git sudo cargo
useradd -m builder

mkdir /pkg

# Install paru as an AUR helper
mkdir /build
cd /build
git clone https://aur.archlinux.org/paru.git
chown -R builder paru
pushd paru
sudo -u builder makepkg
rm -rf /pkg/paru*
mv *.pkg.tar.zst /pkg
popd
rm -rf paru

# Set up environment to build additional packages and build them (if any are given)
if [ "x${INCLUDE_AUR_PACKAGES}" != "x" ]; then
    echo "builder ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-allow-builder

    pacman -U --noconfirm /pkg/paru*.pkg.tar.zst
    sudo -u builder paru --noconfirm --skipreview -Sa "${INCLUDE_AUR_PACKAGES}"
    find /home/builder/.cache/paru -name "*.pkg.tar.*" -exec mv {} /pkg \;
fi

rm -f /pkg/*-debug-*.pkg.tar.*
EOR


FROM docker.io/library/archlinux:latest

ARG NODEJS_PACKAGE="nodejs-lts-krypton"
ARG ADDITIONAL_PACKAGES=""

# Install useful packages for running as a GH Action
RUN --mount=type=bind,from=aurbuilder,source=/pkg,target=/pkg,ro <<EOR
set -euxo pipefail

pacman -Sy
pacman -S --noconfirm \
    base base-devel sudo make just python python-pip python-jinja \
    "${NODEJS_PACKAGE}" npm yarn \
    podman buildah skopeo fuse-overlayfs \
    less git ostree sbsigntools ${ADDITIONAL_PACKAGES}

pacman --noconfirm -U /pkg/*.pkg.tar.*

# Add builder user with sudo permissions
useradd -m builder
echo "builder ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-allow-builder

# Clean up
rm -rf /var/cache/*

mkdir /work
chown -R builder /work
EOR

WORKDIR /work
USER builder

COPY entrypoint.sh /
COPY build-package.sh /usr/local/bin/
ENTRYPOINT ["/entrypoint.sh"]
