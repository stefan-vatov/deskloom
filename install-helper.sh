#!/usr/bin/env bash
set -Eeuo pipefail

readonly package_name="hyprloom"
readonly expected_version="0.3.7"
readonly source_repository="https://github.com/thethracian/hyprloom.git"
readonly source_tag="v0.3.7"
readonly expected_source_commit="2fb3c574afcf64453473c9805c5b72c79b7de047"
readonly expected_source_digest="fb84b8268f7a2c5c16024bd1b675a1628df17d701cbfe3dcdb87d6f7eeca95f8"
readonly local_source="${DESKLOOM_HYPRLOOM_SOURCE:-$HOME/code/hyprloom}"
readonly destination="$HOME/.local/bin/$package_name"
readonly destination_marker="$HOME/.local/bin/.$package_name.sha256"

binary_is_ready() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  [ "$("$binary" --version 2>/dev/null)" = "$package_name $expected_version" ] || return 1
  "$binary" --help >/dev/null 2>&1
}

destination_is_ready() {
  local expected actual
  binary_is_ready "$destination" || return 1
  [ -f "$destination_marker" ] || return 1
  [ ! -L "$destination_marker" ] || return 1
  expected=$(cat -- "$destination_marker")
  actual=$(sha256sum -- "$destination" | cut -d' ' -f1)
  [ "$expected" = "$expected_source_commit $actual" ]
}

write_destination_marker() {
  local digest temporary
  digest=$(sha256sum -- "$destination" | cut -d' ' -f1)
  temporary=$(mktemp "$destination_marker.XXXXXX")
  chmod 600 -- "$temporary"
  printf '%s %s\n' "$expected_source_commit" "$digest" > "$temporary"
  mv -f -- "$temporary" "$destination_marker"
}

install_binary() {
  local binary="$1"
  binary_is_ready "$binary" || return 1
  install -Dm0755 -- "$binary" "$destination"
  binary_is_ready "$destination" || return 1
  write_destination_marker
  destination_is_ready
}

build_from_source() {
  local source="$1"
  source_is_expected "$source" || return 1
  command -v cargo >/dev/null 2>&1 || return 1
  (
    cd -- "$source"
    cargo build --locked --release
  )
  install_binary "$source/target/release/$package_name"
}

source_is_expected() {
  local source="$1"
  [ -f "$source/Cargo.toml" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  [ "$(git -C "$source" rev-parse HEAD 2>/dev/null)" = "$expected_source_commit" ] || return 1
  [ -z "$(git -C "$source" status --porcelain --untracked-files=all 2>/dev/null)" ]
}

packaged_binary() {
  command -v pacman >/dev/null 2>&1 || return 1
  LC_ALL=C pacman -Q "$package_name" >/dev/null 2>&1 || return 1
  LC_ALL=C pacman -Ql "$package_name" 2>/dev/null \
    | awk -v expected="/$package_name" '$2 ~ expected "$" { print $2; exit }'
}

packaged_source_digest() {
  command -v pacman >/dev/null 2>&1 || return 1
  LC_ALL=C pacman -Ql "$package_name" 2>/dev/null \
    | awk -v expected="/usr/share/$package_name/source-digest" '$2 == expected { print $2; exit }'
}

packaged_binary_is_trusted() {
  local binary="$1" ownership installed_version provenance
  binary_is_ready "$binary" || return 1
  installed_version=$(LC_ALL=C pacman -Q "$package_name" 2>/dev/null | awk -v package="$package_name" '$1 == package { print $2; exit }')
  [[ "$installed_version" == "$expected_version"-* ]] || return 1
  provenance=$(packaged_source_digest || true)
  [ -n "$provenance" ] || return 1
  [ -f "$provenance" ] || return 1
  [ ! -L "$provenance" ] || return 1
  [ "$(cat -- "$provenance" 2>/dev/null)" = "$expected_source_digest" ] || return 1
  LC_ALL=C pacman -Qkk "$package_name" >/dev/null 2>&1 || return 1
  ownership=$(LC_ALL=C pacman -Qo -- "$binary" 2>/dev/null) || return 1
  [[ "$ownership" == *" is owned by $package_name $installed_version" ]]
}

if destination_is_ready; then
  exit 0
fi

# Promote an exact package-managed helper into the path Deskloom owns.  This
# avoids accepting a same-version executable that merely happens to appear
# earlier in PATH.
if command -v pacman >/dev/null 2>&1; then
  package_binary=$(packaged_binary || true)
  if [ -n "$package_binary" ] \
    && packaged_binary_is_trusted "$package_binary" \
    && install_binary "$package_binary"; then
    exit 0
  fi
fi

# Let Omarchy's package helper handle the normal Arch/AUR path.  Its terminal
# is intentionally visible, so pacman can ask for the user's sudo password.
if command -v omarchy-pkg-aur-add >/dev/null 2>&1 \
  && omarchy-pkg-aur-add "$package_name"; then
  package_binary=$(packaged_binary || true)
  if [ -n "$package_binary" ] \
    && packaged_binary_is_trusted "$package_binary" \
    && install_binary "$package_binary"; then
    exit 0
  fi
fi

# A local checkout is useful for development installs and for the maintainer's
# own machine before the package has been published to the AUR.
if source_is_expected "$local_source" && build_from_source "$local_source"; then
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
source_is_expected "$source_tmp/source" || {
  echo "hyprloom source tag does not match the expected release commit." >&2
  exit 1
}
build_from_source "$source_tmp/source"
