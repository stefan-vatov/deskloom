#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Omarchy's plugin registry, catalog, and update tooling scan
# $HOME/.config/omarchy/plugins unconditionally; they do not follow
# XDG_CONFIG_HOME. Installing anywhere else produces a tree the shell never
# loads. XDG state/runtime directories keep their base-directory contracts.
config_root="$HOME/.config"
target_dir="$config_root/omarchy/plugins/thethracian.deskloom"
target_parent=$(dirname -- "$target_dir")
umask 077

if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "$(realpath -m -- "$XDG_CONFIG_HOME" 2>/dev/null)" != "$(realpath -m -- "$HOME/.config" 2>/dev/null)" ]; then
  ghost_dir="$XDG_CONFIG_HOME/omarchy/plugins/thethracian.deskloom"
  if [ -e "$ghost_dir" ] || [ -L "$ghost_dir" ]; then
    echo "Note: an old Deskloom install exists under XDG_CONFIG_HOME ($ghost_dir). Omarchy scans only the canonical path ($target_dir), so the old copy was left untouched; remove it manually if it is no longer wanted." >&2
  fi
fi

# Installing over the checkout the installer itself runs from would stage a
# reduced runtime copy over the live directory and then delete the backup
# holding the only full copy of the source, including .git and uncommitted
# work.  Omarchy's public Git plugins are cloned directly into the live
# target, so refuse any physical overlap between the source checkout and the
# target before creating directories, taking locks, staging bytes, or writing
# a transaction marker.  Missing trailing components are allowed; symlinked
# prefixes are resolved.
install_source_path=$(realpath -m -- "$source_dir") || exit 1
install_target_path=$(realpath -m -- "$target_dir") || exit 1
refuse_source_target_overlap() {
  local relationship="$1"
  echo "Deskloom install: refused source-target overlap class=$relationship source_digest=$(printf '%s' "$install_source_path" | sha256sum | cut -c1-12) target_digest=$(printf '%s' "$install_target_path" | sha256sum | cut -c1-12)" >&2
}
case "$install_source_path" in
  "$install_target_path")
    refuse_source_target_overlap source-equals-target
    echo "Refusing to install Deskloom: this checkout is the live plugin target. Run the installer from a separate checkout that is physically disjoint from the live plugin directory." >&2
    exit 1
    ;;
  "$install_target_path"/*)
    refuse_source_target_overlap source-contains-target
    echo "Refusing to install Deskloom: the live plugin target is inside this checkout. Run the installer from a separate checkout that is physically disjoint from the live plugin directory." >&2
    exit 1
    ;;
esac
case "$install_target_path" in
  "$install_source_path"/*)
    refuse_source_target_overlap target-contains-source
    echo "Refusing to install Deskloom: this checkout is inside the live plugin target. Run the installer from a separate checkout that is physically disjoint from the live plugin directory." >&2
    exit 1
    ;;
esac

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
      omarchy plugin enable thethracian.deskloom --after omarchy.tray >/dev/null 2>&1 || return 1
      ;;
    false)
      omarchy plugin disable thethracian.deskloom >/dev/null 2>&1 || return 1
      ;;
    unknown)
      ;;
    *)
      echo "Refusing to restore Deskloom: transaction marker has an invalid enabled state." >&2
      return 1
      ;;
  esac
}

rollback_expectation() {
  # $1: recorded prior enabled state, $2: backup name. A first install (no
  # backup) must end with the plugin absent from the registry; anything else
  # converges to the recorded prior enabled state, or to plain visibility
  # when the prior state is unknown.
  if [ "$2" = none ]; then
    echo absent
    return 0
  fi
  case "$1" in
    true) echo enabled ;;
    false) echo disabled ;;
    *) echo present ;;
  esac
}

registry_matches() {
  local plugin_state_json
  plugin_state_json=$(omarchy plugin list --json) || return 1
  case "$1" in
    enabled)
      jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == true)' >/dev/null <<< "$plugin_state_json"
      ;;
    disabled)
      jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == false)' >/dev/null <<< "$plugin_state_json"
      ;;
    present)
      jq -e 'any(.[]; .id == "thethracian.deskloom")' >/dev/null <<< "$plugin_state_json"
      ;;
    absent)
      jq -e 'all(.[]; .id != "thethracian.deskloom")' >/dev/null <<< "$plugin_state_json"
      ;;
    *)
      return 1
      ;;
  esac
}

perform_registry_rollback() {
  # One checked reconciliation routine shared by restart recovery, the EXIT
  # cleanup, and rollback-registry-pending re-entry. The caller must already
  # have durably recorded the rollback-registry-pending phase; this routine
  # either converges the registry or fails with the marker retained.
  local expectation="$1"
  local max_attempts=20
  local attempt
  for attempt in $(seq 1 "$max_attempts"); do
    if omarchy-shell shell rescanPlugins >/dev/null 2>&1 \
      && restore_plugin_enabled_state "${previous_enabled:-unknown}" \
      && registry_matches "$expectation"; then
      echo "Deskloom install recovery: registry rollback converged attempt=$attempt expectation=$expectation" >&2
      return 0
    fi
    sleep 0.05
  done
  echo "Deskloom install recovery: registry rollback did not converge within $max_attempts attempts; expectation=$expectation. The transaction marker is kept; resolve the plugin registry manually, then remove the marker ($transaction_marker)." >&2
  return 1
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
    prepared|backed-up|installed|committed|rollback-registry-pending) ;;
    *)
      echo "Refusing to recover Deskloom: transaction marker has an unknown phase." >&2
      return 1
      ;;
  esac

  local target_present=false backup_presence=absent target_digest=none
  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    target_present=true
  fi
  if [ -n "$backup_path" ]; then
    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
      backup_presence=present
    else
      backup_presence=missing
    fi
  fi
  if [ "$target_present" = true ]; then
    target_digest=$(cd -- "$target_dir" && find . -mindepth 1 -type f -print0 2>/dev/null \
      | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -c1-12) || target_digest=unavailable
  fi

  local decision=none
  if [ "$backup_presence" = present ]; then
    case "$phase" in
      prepared|backed-up|installed)
        decision=restore-backup
        ;;
      committed)
        if [ "$target_present" = true ]; then
          decision=discard-backup
        else
          decision=restore-backup
        fi
        ;;
    esac
  elif [ "$phase" = installed ] && [ "$target_present" = true ]; then
    if [ "$backup_name" = none ]; then
      # Only a marker that never named a backup proves a first installation:
      # there is no prior plugin, so removing the partial install is the
      # rollback.
      decision=remove-first-install
    else
      # The named backup is gone while an installed plugin exists.  The
      # restore rename may already have put the prior plugin back, so the
      # target cannot be proven disposable.  Never delete it here.
      decision=refuse-ambiguous-restore
    fi
  fi
  echo "Deskloom install recovery: marker_fields=${#fields[@]} phase=$phase backup=$backup_presence target=$target_present target_digest=$target_digest decision=$decision" >&2
  if [ "$decision" = refuse-ambiguous-restore ]; then
    echo "Refusing to recover Deskloom: rollback backup '$backup_name' is missing while an installed plugin exists, so the transaction outcome is ambiguous. Verify the installed plugin is the version you want, then remove the transaction marker ($transaction_marker) to continue." >&2
    return 1
  fi

  if [ "$phase" = rollback-registry-pending ]; then
    # The prior payload was already restored durably by an earlier run.  This
    # phase must never rename or delete payload files: only reconcile the
    # registry and consume the marker once the recorded state holds.
    if [ "$backup_presence" = present ]; then
      echo "Refusing to recover Deskloom: rollback-registry-pending marker still names a backup, so the transaction state is ambiguous. Resolve manually, then remove the transaction marker ($transaction_marker)." >&2
      return 1
    fi
    echo "Deskloom install recovery: resuming pending registry rollback expectation=$(rollback_expectation "$previous_enabled" "$backup_name")" >&2
    if ! perform_registry_rollback "$(rollback_expectation "$previous_enabled" "$backup_name")"; then
      return 1
    fi
    rm -f -- "$transaction_marker"
    sync_path "$backup_root"
    return 0
  fi

  case "$phase" in
    prepared|backed-up|installed)
      registry_dirty=false
      case "$decision" in
        restore-backup)
          if [ "$target_present" = true ]; then
            rm -rf -- "$target_dir"
          fi
          mv -- "$backup_path" "$target_dir"
          registry_dirty=true
          sync_path "$backup_root"
          sync_path "$target_parent"
          ;;
        remove-first-install)
          rm -rf -- "$target_dir"
          registry_dirty=true
          sync_path "$target_parent"
          ;;
      esac
      if [ "$registry_dirty" = true ]; then
        # Record the payload-restored state before touching the registry so a
        # crash here leaves a restartable, non-destructive transaction.
        write_transaction_marker rollback-registry-pending "$backup_name" "$previous_enabled"
        if ! perform_registry_rollback "$(rollback_expectation "$previous_enabled" "$backup_name")"; then
          return 1
        fi
      fi
      ;;
    committed)
      case "$decision" in
        discard-backup)
          rm -rf -- "$backup_path"
          sync_path "$backup_root"
          ;;
        restore-backup)
          mv -- "$backup_path" "$target_dir"
          sync_path "$backup_root"
          sync_path "$target_parent"
          write_transaction_marker rollback-registry-pending "$backup_name" "$previous_enabled"
          if ! perform_registry_rollback "$(rollback_expectation "$previous_enabled" "$backup_name")"; then
            return 1
          fi
          ;;
      esac
      ;;
  esac
  rm -f -- "$transaction_marker"
  sync_path "$backup_root"
}

recover_install_transaction

# Build and validate a complete replacement first.  This keeps a failed
# install from leaving the shell with a half-updated plugin, and removes files
# from older local versions instead of relying on a hand-maintained stale-file
# list.  Staging goes through the same deterministic content-addressed
# packager that produces the published Git artifact, so local and Git
# installs cannot drift.
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
    # post-replacement check fails.  The pending phase is recorded first so a
    # crash or a wedged shell here stays restartable and non-destructive.
    write_transaction_marker rollback-registry-pending "${backup_name:-none}" "$previous_enabled"
    if ! perform_registry_rollback "$(rollback_expectation "${previous_enabled:-unknown}" "${backup_name:-none}")"; then
      echo "Deskloom installation was rolled back on disk but the plugin registry could not be reconciled; the transaction marker was kept for the next run." >&2
    else
      rm -f -- "$transaction_marker"
      sync_path "$backup_root"
    fi
  elif [ "$status" -ne 0 ] && [ "$transaction_committed" = false ] \
    && { [ -e "$transaction_marker" ] || [ -L "$transaction_marker" ]; }; then
    rm -f -- "$transaction_marker"
    sync_path "$backup_root"
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

runtime_entry=$("$source_dir/package-plugin.sh" "$source_dir" "$staging_dir")
# Compile the complete staged panel before anything touches the live plugin;
# a nonzero gate exit aborts here with the gate's diagnostic as the last
# stderr line (canon: installation-safety).
"$source_dir/compile-gate.sh" "$staging_dir"
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

# Canon: registry reload logs alone are not proof of the loaded version.
# When the plugin was previously enabled, require every connected monitor's
# panel instance to acknowledge the exact new content-addressed component
# before the transaction commits.
if [ "$previous_enabled" != "false" ]; then
  ack_ok=false
  monitors_probed=0
  for ack_attempt in $(seq 1 12); do
    ack_ok=true
    monitors_probed=0
    while IFS= read -r monitor; do
      [ -n "$monitor" ] || continue
      monitors_probed=$((monitors_probed + 1))
      reported_component=$(omarchy-shell "thethracian.deskloom.$monitor" status 2>/dev/null </dev/null |
        jq -r '.componentUrl // empty' 2>/dev/null) || reported_component=""
      case "$reported_component" in
        *"$runtime_entry") ;;
        *) ack_ok=false ;;
      esac
    done < <(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null)
    # A monitor listing that yields nothing proves nothing: the component was
    # never probed on any screen, so this attempt cannot acknowledge.
    if [ "$ack_ok" = true ] && [ "$monitors_probed" -gt 0 ]; then
      break
    fi
    sleep 0.25
  done
  if [ "$ack_ok" != true ] || [ "$monitors_probed" -eq 0 ]; then
    echo "The installed panel did not acknowledge the new component on every monitor; the previous install will be restored." >&2
    exit 1
  fi
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
