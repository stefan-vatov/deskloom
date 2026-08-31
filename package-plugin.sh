#!/usr/bin/env bash
set -euo pipefail

# Deterministic content-addressed packager for the Deskloom public plugin
# artifact.
#
#   package-plugin.sh <source-dir> <staging-dir>
#       Stage a complete public plugin artifact: the entry point with its
#       full declared local dependency closure under runtime/<identity>/,
#       plus README.md, install-helper.sh, and a rewritten manifest whose
#       entryPoints.barWidget is the content-addressed component URL.
#
#   package-plugin.sh --check <published-dir>
#       Non-mutating: recompute the identity of the published runtime
#       bundle and prove it matches the published manifest.
#
# Identity covers every shipped byte, its permission mode, and its path
# relative to the bundle root, so identical inputs produce identical URLs
# and any relevant change produces a new one. Local installs and the
# published Git artifact must use this one command so they cannot drift.

usage() {
  echo "usage: $0 <source-dir> <staging-dir>" >&2
  echo "       $0 --check <published-dir>" >&2
  exit 2
}

declare -A seen

# Walk quoted relative imports plus same-directory component type usage,
# transitively from the entry file. Fails on a declared import whose target
# does not exist. External modules (Qt*, Quickshell, qs.*) are not shipped.
collect_closure() {
  local root=$1 entry=$2
  seen=()
  local queue=("$entry")
  while [ ${#queue[@]} -gt 0 ]; do
    local rel=${queue[${#queue[@]} - 1]}
    queue=("${queue[@]:0:${#queue[@]} - 1}")
    [ -z "${seen[$rel]:-}" ] || continue
    seen[$rel]=1
    local file="$root/$rel"
    local dir
    dir=$(dirname -- "$rel")
    local imp relimp
    while IFS= read -r imp; do
      [ -n "$imp" ] || continue
      relimp=$(realpath -m --relative-to="$root" -- "$root/$dir/$imp")
      [ -n "${seen[$relimp]:-}" ] && continue
      if [ ! -f "$root/$relimp" ]; then
        echo "package-plugin: missing local import '$imp' referenced by $rel" >&2
        return 1
      fi
      queue+=("$relimp")
    done < <(sed -n 's/^import "\([^"]*\)".*/\1/p' -- "$file")
    local candidate base name content
    content=$(cat -- "$file")
    for candidate in "$root/$dir"/*.qml "$root/$dir"/*.js; do
      [ -e "$candidate" ] || continue
      base=$(basename -- "$candidate")
      name="${base%.*}"
      [ "$candidate" = "$file" ] && continue
      relimp=$(realpath -m --relative-to="$root" -- "$candidate")
      [ -n "${seen[$relimp]:-}" ] && continue
      if [[ "$content" =~ (^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|$) ]]; then
        queue+=("$relimp")
      fi
    done
  done
  return 0
}

sorted_closure() {
  printf '%s\n' "${!seen[@]}" | LC_ALL=C sort
}

compute_identity() {
  local root=$1
  {
    local rel
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      printf '%s %s\n' "$(stat -c '%a' -- "$root/$rel")" "$rel"
      cat -- "$root/$rel"
    done
  } | sha256sum | cut -d' ' -f1
}

if [ "${1:-}" = "--check" ]; then
  [ $# -eq 2 ] || usage
  published_dir=$2
  manifest="$published_dir/manifest.json"
  [ -f "$manifest" ] || { echo "package-plugin: no manifest at $manifest" >&2; exit 1; }
  entry=$(jq -r '.entryPoints.barWidget' "$manifest")
  case "$entry" in
    runtime/[0-9a-f]*/Panel.qml) ;;
    *) echo "package-plugin: manifest entry '$entry' is not a content-addressed runtime URL" >&2; exit 1 ;;
  esac
  declared=${entry#runtime/}
  declared=${declared%/Panel.qml}
  bundle="$published_dir/runtime/$declared"
  [ -f "$bundle/Panel.qml" ] || { echo "package-plugin: published entry $entry is missing" >&2; exit 1; }
  collect_closure "$bundle" "Panel.qml" || exit 1
  actual=$(sorted_closure | compute_identity "$bundle")
  if [ "$actual" != "$declared" ]; then
    echo "package-plugin: published runtime identity $actual does not match manifest identity $declared" >&2
    exit 1
  fi
  exit 0
fi

[ $# -eq 2 ] || usage
source_dir=$1
staging_dir=$2
[ -f "$source_dir/Panel.qml" ] || { echo "package-plugin: $source_dir/Panel.qml not found" >&2; exit 1; }
[ -f "$source_dir/manifest.json" ] || { echo "package-plugin: $source_dir/manifest.json not found" >&2; exit 1; }

collect_closure "$source_dir" "Panel.qml" || exit 1
identity=$(sorted_closure | compute_identity "$source_dir")
runtime_id="runtime/$identity"

mkdir -p -- "$staging_dir/$runtime_id"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  mkdir -p -- "$staging_dir/$runtime_id/$(dirname -- "$rel")"
  cp --preserve=mode -- "$source_dir/$rel" "$staging_dir/$runtime_id/$rel"
done < <(sorted_closure)

# In-place packaging (staging == source) only adds the versioned bundle and
# rewrites the manifest; the top-level files already exist.
if [ "$(realpath -- "$source_dir")" != "$(realpath -- "$staging_dir")" ]; then
  cp --preserve=mode -- "$source_dir/README.md" "$staging_dir/README.md"
  cp --preserve=mode -- "$source_dir/install-helper.sh" "$staging_dir/install-helper.sh"
fi

temporary=$(mktemp "$staging_dir/.manifest.XXXXXX")
jq --arg entry "$runtime_id/Panel.qml" '.entryPoints.barWidget = $entry' \
  "$source_dir/manifest.json" > "$temporary"
mv -f -- "$temporary" "$staging_dir/manifest.json"

printf '%s\n' "$runtime_id/Panel.qml"
