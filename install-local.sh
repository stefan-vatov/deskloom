#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
target_dir="$config_root/omarchy/plugins/thethracian.deskloom"
umask 077

lock_dir="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/deskloom"
mkdir -p -- "$lock_dir"
chmod 700 -- "$lock_dir"
if ! test -O "$lock_dir"; then
  echo "Refusing to install Deskloom: lock directory is not user-owned: $lock_dir" >&2
  exit 1
fi
exec 9>"$lock_dir/install.lock"
if ! flock -n 9; then
  echo "Another Deskloom installation is already running." >&2
  exit 1
fi

mkdir -p "$(dirname -- "$target_dir")"

# Build and validate a complete replacement first.  This keeps a failed
# install from leaving the shell with a half-updated plugin, and removes files
# from older local versions instead of relying on a hand-maintained stale-file
# list.
staging_dir=$(mktemp -d "${config_root}/.thethracian.deskloom.XXXXXX")
backup_dir=""
target_installed=false
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "${staging_dir:-}" ] && [ -e "$staging_dir" ]; then
    rm -rf -- "$staging_dir"
  fi
  if [ "$status" -ne 0 ] && [ "$target_installed" = true ] && { [ -e "$target_dir" ] || [ -L "$target_dir" ]; }; then
    rm -rf -- "$target_dir"
  fi
  if [ "$status" -ne 0 ] && [ -n "${backup_dir:-}" ] \
    && [ ! -e "$target_dir" ] && [ ! -L "$target_dir" ] \
    && { [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; }; then
    mv -- "$backup_dir" "$target_dir"
    # Restore the shell's plugin registry when a post-replacement check fails.
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
  return "$status"
}
trap cleanup EXIT

install -Dm644 "$source_dir/manifest.json" "$staging_dir/manifest.json"
install -Dm644 "$source_dir/Panel.qml" "$staging_dir/Panel.qml"
install -Dm644 "$source_dir/README.md" "$staging_dir/README.md"
omarchy plugin validate "$staging_dir"

if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
  backup_dir="${target_dir}.old.$$"
  if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
    echo "Refusing to replace plugin: backup path already exists: $backup_dir" >&2
    exit 1
  fi
  mv -- "$target_dir" "$backup_dir"
fi
mv -- "$staging_dir" "$target_dir"
staging_dir=""
target_installed=true

omarchy-shell shell rescanPlugins >/dev/null

registered=false
for _ in {1..40}; do
  if omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom")' >/dev/null; then
    registered=true
    break
  fi
  sleep 0.05
done
if [ "$registered" != true ]; then
  echo "Plugin was not registered after shell rescan; the previous install will be restored." >&2
  exit 1
fi

if ! omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == true)' >/dev/null; then
  omarchy plugin enable thethracian.deskloom --after omarchy.tray
fi
if ! omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == true)' >/dev/null; then
  echo "Plugin was registered but could not be enabled; the previous install will be restored." >&2
  exit 1
fi

if [ -n "$backup_dir" ]; then
  rm -rf -- "$backup_dir"
  backup_dir=""
fi
trap - EXIT

echo "Deskloom installed from $source_dir"
