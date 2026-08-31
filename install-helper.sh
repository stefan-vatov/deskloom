#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly package_name="hyprloom"
readonly expected_version="0.4.0-dev.2"
readonly source_repository="https://github.com/stefan-vatov/hyprloom.git"
readonly expected_source_commit="a9814911541a10cfccb0a58882d3b5235861dcb2"
readonly local_source="${DESKLOOM_HYPRLOOM_SOURCE:-}"
readonly destination_dir="$HOME/.local/bin"
readonly destination="$destination_dir/$package_name"
readonly destination_marker="$destination_dir/.$package_name.sha256"

fail() {
  echo "Deskloom: $*" >&2
  exit 1
}

check_destination() {
  local current="" component mode
  local -a components
  IFS='/' read -r -a components <<< "${destination_dir#/}"
  for component in "${components[@]}"; do
    current="$current/$component"
    [ ! -L "$current" ] || fail "refusing symlinked install directory: $current"
    [ ! -e "$current" ] || [ -d "$current" ] || fail "not an install directory: $current"
  done
  for current in "$HOME/.local" "$destination_dir"; do
    if [ -d "$current" ]; then
      test -O "$current" || fail "install directory is not owned by you: $current"
      mode=$(stat -c '%a' -- "$current")
      (( (8#$mode & 0022) == 0 )) || fail "install directory is writable by another user: $current"
    fi
  done
  for current in "$destination" "$destination_marker"; do
    [ ! -L "$current" ] || fail "refusing symlinked install file: $current"
    [ ! -e "$current" ] || { [ -f "$current" ] && test -O "$current"; } \
      || fail "install file is not a regular file owned by you: $current"
  done
}

binary_is_ready() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  [ "$("$binary" --version 2>/dev/null)" = "$package_name $expected_version" ] || return 1
  "$binary" --help >/dev/null 2>&1
}

destination_is_ready() {
  local expected actual
  [ -f "$destination_marker" ] || return 1
  [ ! -L "$destination_marker" ] || return 1
  expected=$(cat -- "$destination_marker")
  actual=$(sha256sum -- "$destination" | cut -d' ' -f1)
  [ "$expected" = "$expected_source_commit $actual" ] || return 1
  # Provenance is proven: only the pinned, digest-verified bytes may run.
  binary_is_ready "$destination"
}

source_is_expected() {
  local source="$1" status
  [ -f "$source/Cargo.toml" ] && [ -f "$source/Cargo.lock" ] || return 1
  [ "$(git -C "$source" rev-parse HEAD 2>/dev/null)" = "$expected_source_commit" ] || return 1
  status=$(git -C "$source" status --porcelain --untracked-files=all) || return 1
  [ -z "$status" ]
}

check_destination
if destination_is_ready; then
  echo "Hyprloom $expected_version is already installed and verified."
  exit 0
fi

for tool in cargo rustc git cc; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "$tool is required. Install Rust/Cargo, Git and a C toolchain, then retry."
done

source_args=(--git "$source_repository" --rev "$expected_source_commit")
if [ -n "$local_source" ]; then
  source_is_expected "$local_source" \
    || fail "DESKLOOM_HYPRLOOM_SOURCE must be a clean checkout at pinned revision $expected_source_commit."
  source_args=(--path "$local_source")
fi

mkdir -p -- "$destination_dir"
check_destination
lock_file="$destination_dir/.hyprloom-install.lock"
[ ! -L "$lock_file" ] && { [ ! -e "$lock_file" ] || { [ -f "$lock_file" ] && test -O "$lock_file"; }; } \
  || fail "unsafe helper install lock: $lock_file"
exec 8<>"$lock_file"
flock -n 8 || fail "another Hyprloom installation is running."
if destination_is_ready; then exit 0; fi

build_root=$(mktemp -d "${TMPDIR:-/tmp}/deskloom-hyprloom.XXXXXX")
publish_root=""
cleanup() {
  rm -rf -- "$build_root"
  if [ -n "$publish_root" ]; then rm -rf -- "$publish_root"; fi
}
trap cleanup EXIT

echo "Building Hyprloom $expected_version from $source_repository at $expected_source_commit."
echo "Cargo will download dependencies and compile locally; the first build can take several minutes."
if ! cargo install "${source_args[@]}" --locked --bin "$package_name" \
    --root "$build_root/install" --target-dir "$build_root/target"; then
  fail "Cargo build failed; the previous helper was not changed. Check the error above and that the pinned revision is published."
fi
built_binary="$build_root/install/bin/$package_name"
binary_is_ready "$built_binary" || fail "built helper did not pass version/help checks; the previous helper was not changed."
if [ -n "$local_source" ]; then
  source_is_expected "$local_source" || fail "local checkout changed during the build; the previous helper was not changed."
fi

check_destination
publish_root=$(mktemp -d "$destination_dir/.hyprloom-install.XXXXXX")
install -m0755 -- "$built_binary" "$publish_root/hyprloom"
digest=$(sha256sum -- "$publish_root/hyprloom" | cut -d' ' -f1)
printf '%s %s\n' "$expected_source_commit" "$digest" > "$publish_root/marker"
# Publish complete files by rename; until both are present, readiness fails closed.
mv -fT -- "$publish_root/hyprloom" "$destination"
mv -fT -- "$publish_root/marker" "$destination_marker"
destination_is_ready || fail "installed helper verification failed."
echo "Hyprloom $expected_version installed to $destination."
