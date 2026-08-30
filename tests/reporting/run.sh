#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
node --test tests/reporting/model.test.cjs
env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
  -u DBUS_SESSION_BUS_ADDRESS \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
  QT_QUICK_CONTROLS_STYLE=Basic QT_QUICK_BACKEND=software QML_DISABLE_DISK_CACHE=1 \
  /usr/lib/qt6/bin/qmltestrunner \
  -input tests/reporting -import tests/reporting/imports -o -,txt
