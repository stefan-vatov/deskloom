#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
shopt -s nullglob globstar

# Compile gate for local Deskloom installs (production-defect-audit-081.8).
# Synchronously proves the staged QML compiles as a complete panel before
# install-local.sh replaces the live plugin, per
# canon/architecture/installation-safety.md ("Validation must compile the
# complete panel ... not only isolated views").
#
# Phase 1 (lint): qmllint over every QML file in the staged runtime bundle
# with import paths covering the Quickshell module and the qs.* shell
# modules. Errors fail the gate; warnings are acceptable.
#
# Phase 2 (load): the production loader instantiates the staged entry-point
# panel offscreen with the fake-bar/settings pattern of
# tests/native-panel/consent.qml. The probe must print GATE_PASS with no QML
# load errors within a bounded timeout.
#
# Loader note: Omarchy's quickshell package embeds its QML module inside the
# quickshell binary (the on-disk qmldir says "prefer :/qt/qml/Quickshell/"
# and ships only .qmltypes tooling stubs), so qml6 cannot resolve the
# Quickshell module. The load phase therefore runs quickshell itself — the
# same runtime that will load the panel in production — with the same
# offscreen/software isolation the native test harness uses.

usage() {
  echo "usage: $0 <staged-plugin-dir>" >&2
  exit 2
}

gate_log() {
  printf 'compile-gate: %s\n' "$*" >&2
}

# Fails with a sanitized class tag; this line must stay the gate's last
# stderr output so the installer's failure output ends with the diagnosis.
fail() {
  gate_log "FAIL class=$1${2:+ detail=$2}"
  exit 1
}

elapsed_ms() {
  local now=${EPOCHREALTIME/./}
  local start=${1/./}
  echo $(( (now - start) / 1000 ))
}

[ $# -eq 1 ] || usage
staging_dir=${1%/}
probe=""
created_parent=no

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$probe" ] && [ -d "$probe" ]; then
    rm -rf -- "$probe"
  fi
  if [ "$created_parent" = yes ] && [ -d "${tmp_parent:-}" ]; then
    rmdir -- "$tmp_parent" 2>/dev/null || true
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- inputs -----------------------------------------------------------------
[ -d "$staging_dir" ] || fail missing-staging
# Canonical form keeps the diagnostic sanitizer from matching short relative
# paths inside unrelated words.
staging_dir=$(realpath -m -- "$staging_dir" 2>/dev/null || printf '%s\n' "$staging_dir")
manifest="$staging_dir/manifest.json"
[ -f "$manifest" ] || fail missing-manifest
entry=$(jq -er '.entryPoints.barWidget' "$manifest" 2>/dev/null) || fail missing-entry
entry_component=$(basename -- "$entry")
entry_component=${entry_component%.qml}
[ -n "$entry_component" ] || fail missing-entry
[ -f "$staging_dir/$entry" ] || fail missing-entry
case "$entry" in
  runtime/*/*.qml) bundle_dir=$(dirname -- "$staging_dir/$entry") ;;
  *) fail bad-entry ;;
esac

lint_bin=""
if command -v qmllint6 >/dev/null 2>&1; then
  lint_bin=$(command -v qmllint6)
elif [ -x /usr/lib/qt6/bin/qmllint ]; then
  lint_bin=/usr/lib/qt6/bin/qmllint
elif [ -x /usr/lib/qt6/bin/qmllint6 ]; then
  lint_bin=/usr/lib/qt6/bin/qmllint6
fi
[ -n "$lint_bin" ] || fail missing-tool detail=qmllint

loader_bin=""
if command -v quickshell >/dev/null 2>&1; then
  loader_bin=$(command -v quickshell)
elif [ -x /usr/bin/quickshell ]; then
  loader_bin=/usr/bin/quickshell
fi
[ -n "$loader_bin" ] || fail missing-tool detail=quickshell

shell_root=/usr/share/omarchy/shell
if [ ! -d "$shell_root/Commons" ] || [ ! -d "$shell_root/Ui" ]; then
  fail missing-omarchy-shell
fi

# --- disposable probe, unique and trap-cleaned -----------------------------
# Prefer /tmp/$UID; fall back to the staged artifact's parent, which is
# writable by construction (the installer created it) in sandboxes where /tmp
# is read-only.
tmp_parent="/tmp/$(id -u)"
if [ -d "$tmp_parent" ] && [ -O "$tmp_parent" ] && [ -w "$tmp_parent" ]; then
  : # usable
else
  tmp_parent=$(dirname -- "$staging_dir")
fi
if [ -d "$tmp_parent" ]; then
  [ -O "$tmp_parent" ] || fail unsafe-probe-parent
else
  mkdir -m 0700 -- "$tmp_parent" 2>/dev/null || fail unsafe-probe-parent
  created_parent=yes
fi
probe=$(mktemp -d "$tmp_parent/compile-gate.XXXXXX") || fail probe-setup
chmod 0700 -- "$probe"

mkdir -p -- "$probe/qs" "$probe/production" "$probe/bin" \
  "$probe/home/.local/bin" "$probe/home/rt"
cp -r -- "$shell_root/Commons" "$shell_root/Ui" "$probe/"
ln -s ../Commons "$probe/qs/Commons"
ln -s ../Ui "$probe/qs/Ui"
cp -r -- "$bundle_dir/." "$probe/production/"

# The panel's process boundaries never run during the gate: both shell
# commands are inert fakes (list prints an empty snapshot collection).
for name in omarchy omarchy-shell; do
  printf '#!/bin/sh\nif [ "${1:-}" = list ]; then echo "[]"; fi\nexit 0\n' > "$probe/bin/$name"
  chmod 755 -- "$probe/bin/$name"
done

# Probe shell: instantiates the staged entry-point panel exactly as the
# production bar hosts it (fake bar object, plugin settings object).
cat > "$probe/shell.qml" <<EOF
import QtQuick
import Quickshell
import qs.Commons
import "production" as Production
Window {
  id: gate
  width: 800; height: 900; visible: true
  color: Color.background
  QtObject {
    id: fakeBar
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color urgent: Color.urgent
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
    function showTooltip(owner, text) {}
    function hideTooltip(owner) {}
    function requestPopout(owner) {}
    function releasePopout(owner) {}
  }
  Production.$entry_component {
    id: panel
    anchors.fill: parent
    bar: fakeBar
    settings: ({ startOnLogin: false, defaultPreset: "" })
  }
  Timer { interval: 300; running: true; onTriggered: { console.log("GATE_PASS"); Qt.quit() } }
}
EOF

# The gate logs phases without host paths: every diagnostic is passed through
# this sanitizer before it reaches stderr.
sanitize() {
  sed -e "s|$probe|<probe>|g" \
      -e "s|$staging_dir|<staged>|g" \
      -e "s|$tmp_parent|<tmp>|g"
}

# --- phase 1: lint -----------------------------------------------------------
lint_files=("$probe/production"/**/*.qml)
if [ "${#lint_files[@]}" -eq 0 ]; then
  fail lint-error detail=no-qml-files
fi
gate_log "lint start files=${#lint_files[@]}"
lint_start=$EPOCHREALTIME
lint_rc=0
"$lint_bin" -I "$probe" -I /usr/lib/qt6/qml "${lint_files[@]}" \
  > "$probe/lint.log" 2>&1 || lint_rc=$?
lint_ms=$(elapsed_ms "$lint_start")
if [ "$lint_rc" -ne 0 ]; then
  gate_log "lint finish elapsed_ms=$lint_ms outcome=fail"
  sanitize < "$probe/lint.log" | sed -n '1,40p' >&2
  fail lint-error
fi
gate_log "lint finish elapsed_ms=$lint_ms outcome=pass"

# --- phase 2: load the complete panel ---------------------------------------
gate_log "load start loader=quickshell"
load_start=$EPOCHREALTIME
load_rc=0
env -i \
  HOME="$probe/home" \
  PATH="$probe/bin:/usr/bin:/bin" \
  XDG_RUNTIME_DIR="$probe/home/rt" \
  QT_QPA_PLATFORM=offscreen \
  QT_QUICK_BACKEND=software \
  QML_DISABLE_DISK_CACHE=1 \
  QT_FORCE_STDERR_LOGGING=1 \
  LANG=C.UTF-8 \
  timeout 10 "$loader_bin" --path "$probe/shell.qml" \
  > "$probe/load.log" 2>&1 || load_rc=$?
load_ms=$(elapsed_ms "$load_start")
load_output=$(cat -- "$probe/load.log")

load_fail() {
  gate_log "load finish elapsed_ms=$load_ms outcome=fail"
  printf '%s\n' "$load_output" | sanitize | tail -n 20 >&2
  fail "$1"
}

if [ "$load_rc" -eq 124 ] || [ "$load_rc" -eq 137 ]; then
  load_fail load-timeout
elif [ "$load_rc" -ne 0 ]; then
  load_fail load-error
elif [[ "$load_output" =~ Failed\ to\ load\ configuration|GATE_FAIL|(TypeError|ReferenceError|SyntaxError|RangeError):|Unable\ to\ assign ]]; then
  load_fail load-error
elif [[ "$load_output" != *GATE_PASS* ]]; then
  load_fail load-incomplete
fi
gate_log "load finish elapsed_ms=$load_ms outcome=pass"

gate_log "pass lint_ms=$lint_ms load_ms=$load_ms"
