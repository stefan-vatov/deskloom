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
backup_root="$config_root/omarchy/.deskloom-rollback"
transaction_marker="$backup_root/transaction"
mkdir -p -- "$backup_root"
chmod 700 -- "$backup_root"
if ! test -O "$backup_root"; then
  echo "Refusing to install Deskloom: rollback directory is not user-owned: $backup_root" >&2
  exit 1
fi

write_transaction_marker() {
  local phase="$1"
  local backup_name="$2"
  local temporary
  temporary=$(mktemp "$backup_root/.transaction.XXXXXX")
  chmod 600 -- "$temporary"
  printf '%s\n%s\n' "$phase" "$backup_name" > "$temporary"
  mv -f -- "$temporary" "$transaction_marker"
}

recover_install_transaction() {
  if [ ! -e "$transaction_marker" ] && [ ! -L "$transaction_marker" ]; then
    return 0
  fi
  if [ -L "$transaction_marker" ] || [ ! -f "$transaction_marker" ]; then
    echo "Refusing to recover Deskloom: transaction marker is not a regular file." >&2
    return 1
  fi
  if ! test -O "$transaction_marker" || [ "$(stat -c '%a' "$transaction_marker")" != 600 ]; then
    echo "Refusing to recover Deskloom: transaction marker is not private and user-owned." >&2
    return 1
  fi

  local -a fields=()
  mapfile -t fields < "$transaction_marker"
  if [ "${#fields[@]}" -ne 2 ]; then
    echo "Refusing to recover Deskloom: transaction marker is malformed." >&2
    return 1
  fi

  local phase="${fields[0]}"
  local backup_name="${fields[1]}"
  local backup_path=""
  case "$backup_name" in
    none) ;;
    deskloom.old.[0-9]*) backup_path="$backup_root/$backup_name" ;;
    *)
      echo "Refusing to recover Deskloom: transaction marker names an unsafe backup." >&2
      return 1
      ;;
  esac
  if [ -n "$backup_path" ] && [ -L "$backup_path" ]; then
    echo "Refusing to recover Deskloom: rollback backup is a symlink." >&2
    return 1
  fi
  if [ -n "$backup_path" ] && [ -e "$backup_path" ] && [ ! -d "$backup_path" ]; then
    echo "Refusing to recover Deskloom: rollback backup is not a directory." >&2
    return 1
  fi
  case "$phase" in
    prepared|backed-up|installed|committed) ;;
    *)
      echo "Refusing to recover Deskloom: transaction marker has an unknown phase." >&2
      return 1
      ;;
  esac

  case "$phase" in
    prepared|backed-up|installed)
      if [ -n "$backup_path" ] && { [ -e "$backup_path" ] || [ -L "$backup_path" ]; }; then
        if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
          rm -rf -- "$target_dir"
        fi
        mv -- "$backup_path" "$target_dir"
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
      elif [ "$phase" = installed ] && { [ -e "$target_dir" ] || [ -L "$target_dir" ]; }; then
        # This was a first install.  There is no prior plugin to restore.
        rm -rf -- "$target_dir"
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
      fi
      ;;
    committed)
      if [ -n "$backup_path" ] && { [ -e "$backup_path" ] || [ -L "$backup_path" ]; }; then
        if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
          rm -rf -- "$backup_path"
        elif [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
          mv -- "$backup_path" "$target_dir"
          omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
        fi
      fi
      ;;
  esac
  rm -f -- "$transaction_marker"
}

recover_install_transaction

# Build and validate a complete replacement first.  This keeps a failed
# install from leaving the shell with a half-updated plugin, and removes files
# from older local versions instead of relying on a hand-maintained stale-file
# list.
staging_dir=$(mktemp -d "${config_root}/.thethracian.deskloom.XXXXXX")
backup_dir=""
target_installed=false
transaction_committed=false
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "${staging_dir:-}" ] && [ -e "$staging_dir" ]; then
    rm -rf -- "$staging_dir"
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && [ "$target_installed" = true ] \
    && { [ -e "$target_dir" ] || [ -L "$target_dir" ]; }; then
    rm -rf -- "$target_dir"
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && [ -n "${backup_dir:-}" ] \
    && [ ! -e "$target_dir" ] && [ ! -L "$target_dir" ] \
    && { [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; }; then
    mv -- "$backup_dir" "$target_dir"
    # Restore the shell's plugin registry when a post-replacement check fails.
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && { [ -e "$transaction_marker" ] || [ -L "$transaction_marker" ]; }; then
    rm -f -- "$transaction_marker"
  fi
  return "$status"
}
trap cleanup EXIT

install -Dm644 "$source_dir/manifest.json" "$staging_dir/manifest.json"
install -Dm644 "$source_dir/Panel.qml" "$staging_dir/Panel.qml"
install -Dm644 "$source_dir/README.md" "$staging_dir/README.md"
omarchy plugin validate "$staging_dir"

if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
  if [ -L "$target_dir" ]; then
    echo "Refusing to replace Deskloom: installed plugin path is a symlink: $target_dir" >&2
    exit 1
  fi
  backup_name="deskloom.old.$$"
  backup_dir="$backup_root/$backup_name"
  if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
    echo "Refusing to replace plugin: backup path already exists: $backup_dir" >&2
    exit 1
  fi
else
  backup_name="none"
fi
write_transaction_marker prepared "$backup_name"
if [ -n "$backup_dir" ]; then
  # Record the intended backup state before the move.  If the process dies
  # between the move and the next marker update, recovery still knows that an
  # existing backup must be put back.
  write_transaction_marker backed-up "$backup_name"
  mv -- "$target_dir" "$backup_dir"
fi
# Record the point at which the old plugin is safely recoverable (or that this
# is a first install) before moving the staged tree into place.  That makes a
# crash before the final move recoverable too: an existing backup is restored,
# while a first-install target is removed if it was already moved.
write_transaction_marker installed "$backup_name"
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

write_transaction_marker committed "$backup_name"
transaction_committed=true
if [ -n "$backup_dir" ]; then
  rm -rf -- "$backup_dir"
  backup_dir=""
fi
rm -f -- "$transaction_marker"
trap - EXIT

echo "Deskloom installed from $source_dir"
