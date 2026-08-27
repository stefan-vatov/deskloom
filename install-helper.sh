#!/usr/bin/env bash
set -Eeuo pipefail

readonly package_name="hyprloom"
readonly source_repository="https://github.com/thethracian/hyprloom.git"
readonly source_tag="v0.3.0"
readonly local_source="${DESKLOOM_HYPRLOOM_SOURCE:-$HOME/code/hyprloom}"
readonly destination="$HOME/.local/bin/$package_name"

binary_is_ready() {
  local binary="$1"
  [ -x "$binary" ] && "$binary" --help >/dev/null 2>&1
}

install_binary() {
  local binary="$1"
  binary_is_ready "$binary" || return 1
  install -Dm0755 -- "$binary" "$destination"
  binary_is_ready "$destination"
}

build_from_source() {
  local source="$1"
  [ -f "$source/Cargo.toml" ] || return 1
  command -v cargo >/dev/null 2>&1 || return 1
  (
    cd -- "$source"
    cargo build --locked --release
  )
  install_binary "$source/target/release/$package_name"
}

if command -v "$package_name" >/dev/null 2>&1 \
  && "$package_name" --help >/dev/null 2>&1; then
  exit 0
fi

# Let Omarchy's package helper handle the normal Arch/AUR path.  Its terminal
# is intentionally visible, so pacman can ask for the user's sudo password.
if command -v omarchy-pkg-aur-add >/dev/null 2>&1 \
  && omarchy-pkg-aur-add "$package_name" \
  && command -v "$package_name" >/dev/null 2>&1 \
  && "$package_name" --help >/dev/null 2>&1; then
  exit 0
fi

# A local checkout is useful for development installs and for the maintainer's
# own machine before the package has been published to the AUR.
if [ -x "$local_source/target/release/$package_name" ] \
  && install_binary "$local_source/target/release/$package_name"; then
  exit 0
fi
if build_from_source "$local_source"; then
  exit 0
fi

# Marketplace installs do not execute repository hooks.  After the fork's tag
# is published, this source fallback makes the panel's one-click installer
# useful even while the AUR package is still pending.  It builds locally rather
# than installing an unverified binary downloaded from a release page.
command -v git >/dev/null 2>&1 || {
  echo "hyprloom is not installed: git is required for the source fallback." >&2
  exit 1
}
command -v cargo >/dev/null 2>&1 || {
  echo "hyprloom is not installed: cargo is required for the source fallback." >&2
  exit 1
}

source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/deskloom-hyprloom.XXXXXX")
trap 'rm -rf -- "$source_tmp"' EXIT
git clone --quiet --depth 1 --branch "$source_tag" "$source_repository" "$source_tmp/source"
build_from_source "$source_tmp/source"
