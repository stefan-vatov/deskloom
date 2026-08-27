import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property bool bootAttempted: false

  function pluginEntry() {
    var config = root.shell ? root.shell.shellConfig : null
    if (!config || !config.bar || !config.bar.layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = config.bar.layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && entries[i].id === "thethracian.deskloom") return entries[i]
      }
    }
    return null
  }

  function restoreAtBoot() {
    if (bootAttempted) return
    bootAttempted = true

    var entry = pluginEntry()
    if (!entry || entry.startOnLogin !== true || String(entry.defaultPreset || "") === "") return

    pendingPreset = String(entry.defaultPreset)
    helperProbe.running = true
  }

  property string pendingPreset: ""

  Timer {
    interval: 4000
    repeat: false
    running: true
    onTriggered: root.restoreAtBoot()
  }

  Process {
    id: helperProbe
    command: ["bash", "-c", "command -v hyprflow >/dev/null 2>&1"]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("Deskloom: default preset skipped because hyprflow is not installed")
        return
      }
      restoreProcess.command = ["hyprflow", "restore", root.pendingPreset]
      restoreProcess.running = true
    }
  }

  Process {
    id: restoreProcess
    onExited: function(exitCode) {
      if (exitCode === 0)
        console.log("Deskloom: restored default preset '" + root.pendingPreset + "'")
      else
        console.warn("Deskloom: default preset restore failed for '" + root.pendingPreset + "'")
    }
  }
}
