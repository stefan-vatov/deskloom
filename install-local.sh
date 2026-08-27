#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
target_dir="$config_root/omarchy/plugins/thethracian.deskloom"

mkdir -p "$target_dir"
install -Dm644 "$source_dir/manifest.json" "$target_dir/manifest.json"
install -Dm644 "$source_dir/Panel.qml" "$target_dir/Panel.qml"
install -Dm644 "$source_dir/Service.qml" "$target_dir/Service.qml"
install -Dm644 "$source_dir/README.md" "$target_dir/README.md"

omarchy plugin validate "$target_dir"
omarchy-shell shell rescanPlugins >/dev/null

for _ in {1..40}; do
  if omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom")' >/dev/null; then
    break
  fi
  sleep 0.05
done

if ! omarchy plugin list --json | jq -e 'any(.[]; .id == "thethracian.deskloom" and .enabled == true)' >/dev/null; then
  omarchy plugin enable thethracian.deskloom --after omarchy.tray
fi

echo "Deskloom installed from $source_dir"
