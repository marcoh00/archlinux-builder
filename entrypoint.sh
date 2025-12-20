#!/usr/bin/bash

set -euxo pipefail

ACTION="${1:-build-package}"
TARGET="${2:-.}"
ARTIFACTS="${3:-output}"
PACKAGER="${5:-GitHub Actions Packager}"

ROOT="$(pwd)"
FULL_ARTIFACTS="$ROOT/$ARTIFACTS"

MAKEPKG_FLAGS="-f"
REPO_ADD_FLAGS="-p"

BUILDER_USER="builder"

sudo chown -R "$BUILDER_USER" .
sudo mkdir -p /github/home
sudo chown -R "$BUILDER_USER" /github/home

remove_gpglocks() {
  # Sometimes, previous uses seem to leave lock files, so we remove them
  GNUPGDIR=$1

  if [ -d "$GNUPGDIR" ]; then
    sudo find "$GNUPGDIR" -name "*.lock" -exec rm -f {} \;
  fi
}

set +x
GPGSIGN="${4:-}"
KEYID=""
if [ ! "x${GPGSIGN:-}" = "x" ]; then
  # In case we're operating in a stateful system like GH Actions, reset the GnuPG state and remove locks, if neccessary
  rm -rf ~/.gnupg
  remove_gpglocks /etc/pacman.d/gnupg
  # KEYID has not been set, so the key wasn't imported yet
  if [ "x${KEYID}" = "x" ]; then
    # Add key to the builder keyring, because it will be needed for signing
    echo "GPG key specified. Importing (builder)..."
    echo "$GPGSIGN" | gpg --no-tty --import

    KEYID=$(gpg --no-tty --list-keys | grep -P "\s*[A-F0-9]{32,64}" | tr -d '[:blank:]')
    echo "Key ID is $KEYID"

    # We need to import the public key explicitly to be able to trust it later
    echo "GPG key imported. Export Public Key..."
    gpg -a --export $KEYID >pubkey.asc

    # "Trust gpg key via script": https://serverfault.com/questions/1010704/trust-gpg-key-via-script
    echo "Setting trust level (builder keyring)..."
    echo -e "5\ny\n" | gpg --no-tty --command-fd 0 --edit-key "$KEYID" trust

    # If the container is just restarted with an old state, this may fail, because the key is already known.
    # If there was some other error, the following step will fail anyway.
    sudo env GNUPGHOME=/etc/pacman.d/gnupg gpg --import pubkey.asc || true
    echo -e "5\ny\n" | sudo env GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --command-fd 0 --edit-key "$KEYID" trust

    REPO_ADD_FLAGS="$REPO_ADD_FLAGS --sign --key $KEYID"
    MAKEPKG_FLAGS="$MAKEPKG_FLAGS --sign --key $KEYID"
  fi
fi
set -x

if [ "x$ACTION" = "xbuild-package" ]; then
  sudo pacman -Sy
  sudo mkdir -p "$FULL_ARTIFACTS"
  sudo chown -R "$BUILDER_USER" "$FULL_ARTIFACTS"
  for pkg in $TARGET; do
    sudo chown -R "$BUILDER_USER" "$pkg"
    build-package.sh "$pkg" "$ARTIFACTS" "$KEYID" "$PACKAGER"
  done
  exit 0
fi

if [ "x$ACTION" = "xbuild-aur" ]; then
  sudo pacman -Sy
  sudo mkdir -p "$FULL_ARTIFACTS"
  sudo chown -R "$BUILDER_USER" "$FULL_ARTIFACTS"
  PACKAGES=""
  for pkg in $TARGET; do
    PACKAGES="$PACKAGES $pkg"
  done
  GIT_PAGER=cat PACKAGER="$PACKAGER" paru --noconfirm --skipreview --mflags "$MAKEPKG_FLAGS" -Sa $PACKAGES
  find ~/.cache/paru/clone \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.zst.sig" \) -exec mv {} "$FULL_ARTIFACTS" \;
  exit 0
fi

if [ "x$ACTION" = "xbuild-repo" ]; then
  sudo chown -R "$BUILDER_USER" "$TARGET"
  cd "$TARGET"
  # Sanitize filenames. Otherwise, other systems might mess with them.
  # For example, GH Releases will replace colons with periods, making the db reference invalid.
  for file in *.pkg.tar.zst; do
    SANITIZED=$(echo "$file" | sed -e 's/[^A-Za-z0-9._-]/./g')
    if [ "$file" != "$SANITIZED" ]; then
      mv "$file" "$SANITIZED"
    fi
  done
  repo-add $REPO_ADD_FLAGS "${ARTIFACTS}.db.tar.zst" *.pkg.tar.zst
  cd "$ROOT"

  exit 0
fi

if [ "x$ACTION" = "xexec" ]; then
  exec $TARGET
fi

exec $@
