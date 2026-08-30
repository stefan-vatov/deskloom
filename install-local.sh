#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
target_dir="$config_root/omarchy/plugins/thethracian.deskloom"
target_parent=$(dirname -- "$target_dir")
umask 077

ensure_no_symlink_ancestors() {
  local normalized component current=""
  normalized=$(realpath -m -s -- "$1")
  IFS='/' read -r -a components <<< "${normalized#/}"
  for component in "${components[@]}"; do
    [ -z "$component" ] && continue
    current="$current/$component"
    if [ -L "$current" ]; then
      echo "Refusing to use a symlinked path component: $current" >&2
      return 1
    fi
  done
}

ensure_safe_dir() {
  local path="$1"
  local mode mode_value
  ensure_no_symlink_ancestors "$path"
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    echo "Refusing to use a non-directory path: $path" >&2
    return 1
  fi
  if ! test -O "$path"; then
    echo "Refusing to use a directory not owned by this user: $path" >&2
    return 1
  fi
  mode=$(stat -c '%a' -- "$path")
  mode_value=$((8#$mode))
  if (( mode_value & 0022 )); then
    echo "Refusing to use a directory writable by another user: $path" >&2
    return 1
  fi
}

sync_path() {
  # GNU sync -f flushes the file system containing the path, including the
  # metadata needed for the rename-based transaction checkpoints below.
  command sync -f -- "$1"
}

ensure_no_symlink_ancestors "$config_root"
mkdir -p -- "$config_root"
ensure_safe_dir "$config_root"
mkdir -p -- "$config_root/omarchy/plugins"
ensure_safe_dir "$config_root/omarchy"
ensure_safe_dir "$config_root/omarchy/plugins"

lock_dir="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/deskloom"
ensure_no_symlink_ancestors "$lock_dir"
mkdir -p -- "$lock_dir"
chmod 700 -- "$lock_dir"
ensure_safe_dir "$lock_dir"
lock_path="$lock_dir/install.lock"
if [ -L "$lock_path" ] || { [ -e "$lock_path" ] && [ ! -f "$lock_path" ]; }; then
  echo "Refusing to use a non-regular install lock: $lock_path" >&2
  exit 1
fi
if [ -f "$lock_path" ] && ! test -O "$lock_path"; then
  echo "Refusing to use an install lock not owned by this user: $lock_path" >&2
  exit 1
fi
# Open without truncating an existing lock file.  The lock directory is private
# and the target is checked above, so a sentinel or prior lock contents survive
# a failed/repeated installation.
exec 9<>"$lock_path"
if ! flock -n 9; then
  echo "Another Deskloom installation is already running." >&2
  exit 1
fi

backup_root="$config_root/omarchy/.deskloom-rollback"
transaction_marker="$backup_root/transaction"
ensure_no_symlink_ancestors "$backup_root"
mkdir -p -- "$backup_root"
chmod 700 -- "$backup_root"
ensure_safe_dir "$backup_root"
ensure_no_symlink_ancestors "$target_dir"

write_transaction_marker() {
  local phase="$1"
  local backup_name="$2"
  local enabled_state="${3:-$previous_enabled}"
  local temporary
  temporary=$(mktemp "$backup_root/.transaction.XXXXXX")
  chmod 600 -- "$temporary"
  printf '%s\n%s\n%s\n' "$phase" "$backup_name" "$enabled_state" > "$temporary"
  sync_path "$temporary"
  mv -f -- "$temporary" "$transaction_marker"
  sync_path "$backup_root"
}

restore_plugin_enabled_state() {
  case "$1" in
    true)
      omarchy plugin enable thethracian.deskloom --after omarchy.tray >/dev/null 2>&1 || true
      ;;
    false)
      omarchy plugin disable thethracian.deskloom >/dev/null 2>&1 || true
      ;;
    unknown)
      ;;
    *)
      echo "Refusing to restore Deskloom: transaction marker has an invalid enabled state." >&2
      return 1
      ;;
  esac
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
  if [ "${#fields[@]}" -lt 2 ] || [ "${#fields[@]}" -gt 3 ]; then
    echo "Refusing to recover Deskloom: transaction marker is malformed." >&2
    return 1
  fi

  local phase="${fields[0]}"
  local backup_name="${fields[1]}"
  local previous_enabled="${fields[2]:-unknown}"
  case "$previous_enabled" in
    true|false|unknown) ;;
    *)
      echo "Refusing to recover Deskloom: transaction marker has an invalid enabled state." >&2
      return 1
      ;;
  esac
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
  if [ -n "$backup_path" ] && [ -e "$backup_path" ]; then
    ensure_safe_dir "$backup_path"
  fi
  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    if [ -L "$target_dir" ]; then
      echo "Refusing to recover Deskloom: installed plugin path is a symlink." >&2
      return 1
    fi
    ensure_safe_dir "$target_dir"
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
      registry_dirty=false
      if [ -n "$backup_path" ] && { [ -e "$backup_path" ] || [ -L "$backup_path" ]; }; then
        if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
          rm -rf -- "$target_dir"
        fi
        mv -- "$backup_path" "$target_dir"
        registry_dirty=true
        sync_path "$backup_root"
        sync_path "$target_parent"
      elif [ "$phase" = installed ] && { [ -e "$target_dir" ] || [ -L "$target_dir" ]; }; then
        # This was a first install.  There is no prior plugin to restore.
        rm -rf -- "$target_dir"
        registry_dirty=true
        sync_path "$target_parent"
      fi
      if [ "$registry_dirty" = true ]; then
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
        restore_plugin_enabled_state "$previous_enabled"
      fi
      ;;
    committed)
      if [ -n "$backup_path" ] && { [ -e "$backup_path" ] || [ -L "$backup_path" ]; }; then
        if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
          rm -rf -- "$backup_path"
          sync_path "$backup_root"
        elif [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
          mv -- "$backup_path" "$target_dir"
          omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
          sync_path "$backup_root"
          sync_path "$target_parent"
        fi
      fi
      ;;
  esac
  rm -f -- "$transaction_marker"
  sync_path "$backup_root"
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
previous_enabled=unknown
cleanup() {
  local status=$?
  trap - EXIT
  local registry_dirty=false
  if [ -n "${staging_dir:-}" ] && [ -e "$staging_dir" ]; then
    rm -rf -- "$staging_dir"
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && [ "$target_installed" = true ] \
    && { [ -e "$target_dir" ] || [ -L "$target_dir" ]; }; then
    rm -rf -- "$target_dir"
    registry_dirty=true
    sync_path "$target_parent"
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && [ -n "${backup_dir:-}" ] \
    && [ ! -e "$target_dir" ] && [ ! -L "$target_dir" ] \
    && { [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; }; then
    mv -- "$backup_dir" "$target_dir"
    registry_dirty=true
    sync_path "$backup_root"
    sync_path "$target_parent"
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && [ "$registry_dirty" = true ]; then
    # Restore the shell's plugin registry and enabled state when a
    # post-replacement check fails.
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    restore_plugin_enabled_state "$previous_enabled"
  fi
  if [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && { [ -e "$transaction_marker" ] || [ -L "$transaction_marker" ]; }; then
    rm -f -- "$transaction_marker"
    sync_path "$backup_root"
  fi
  return "$status"
}
trap cleanup EXIT

runtime_files=(Panel.qml RestoreReport.js RestoreReportView.qml RestoreReportPopup.qml)
# A long-running QML engine may cache components by URL even after a registry
# rescan. Give changed code and all its local imports a fresh, immutable URL.
runtime_revision=$(cd -- "$source_dir" && sha256sum -- "${runtime_files[@]}" | sha256sum | cut -d' ' -f1)
runtime_entry="runtime/$runtime_revision/Panel.qml"
for runtime_file in "${runtime_files[@]}"; do
  install -Dm644 "$source_dir/$runtime_file" "$staging_dir/runtime/$runtime_revision/$runtime_file"
done
jq --arg entry "$runtime_entry" '.entryPoints.barWidget = $entry' "$source_dir/manifest.json" > "$staging_dir/manifest.json"
install -Dm644 "$source_dir/README.md" "$staging_dir/README.md"
install -Dm0755 "$source_dir/install-helper.sh" "$staging_dir/install-helper.sh"
omarchy plugin validate "$staging_dir"

plugin_state_json=$(omarchy plugin list --json)
previous_enabled=$(jq -r \
  'first(.[] | select(.id == "thethracian.deskloom") | if .enabled == true then "true" else "false" end) // "unknown"' \
  <<< "$plugin_state_json")

if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
  if [ -L "$target_dir" ]; then
    echo "Refusing to replace Deskloom: installed plugin path is a symlink: $target_dir" >&2
    exit 1
  fi
  ensure_safe_dir "$target_dir"
  backup_name="deskloom.old.$$"
  backup_dir="$backup_root/$backup_name"
  if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
    echo "Refusing to replace plugin: backup path already exists: $backup_dir" >&2
    exit 1
  fi
else
  backup_name="none"
fi
write_transaction_marker prepared "$backup_name" "$previous_enabled"
if [ -n "$backup_dir" ]; then
  # Record the intended backup state before the move.  If the process dies
  # between the move and the next marker update, recovery still knows that an
  # existing backup must be put back.
  write_transaction_marker backed-up "$backup_name" "$previous_enabled"
  mv -- "$target_dir" "$backup_dir"
  sync_path "$backup_root"
  sync_path "$target_parent"
fi
# Record the point at which the old plugin is safely recoverable (or that this
# is a first install) before moving the staged tree into place.  That makes a
# crash before the final move recoverable too: an existing backup is restored,
# while a first-install target is removed if it was already moved.
write_transaction_marker installed "$backup_name" "$previous_enabled"
mv -- "$staging_dir" "$target_dir"
staging_dir=""
target_installed=true
sync_path "$target_parent"

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

if [ "$previous_enabled" = unknown ] \
  && ! omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == true)' >/dev/null; then
  omarchy plugin enable thethracian.deskloom --after omarchy.tray
fi
if [ "$previous_enabled" = unknown ] \
  && ! omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == true)' >/dev/null; then
  echo "Plugin was registered but could not be enabled; the previous install will be restored." >&2
  exit 1
fi

write_transaction_marker committed "$backup_name" "$previous_enabled"
transaction_committed=true
if [ -n "$backup_dir" ]; then
  rm -rf -- "$backup_dir"
  backup_dir=""
  sync_path "$backup_root"
fi
rm -f -- "$transaction_marker"
sync_path "$backup_root"
trap - EXIT

echo "Deskloom installed from $source_dir"
