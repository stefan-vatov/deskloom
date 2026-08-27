import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "thethracian.deskloom"
  ipcTarget: "thethracian.deskloom"
  manageIpc: false

  property bool helperInstalled: false
  property bool busy: false
  property bool installingHelper: false
  property bool settingsOpen: false
  property string statusText: ""
  property string saveName: "work"
  property string pendingDeleteName: ""
  property string pendingReplaceName: ""
  property string operationKind: ""
  property var snapshots: []

  readonly property bool startOnLogin: setting("startOnLogin", false) === true
  readonly property string defaultPreset: String(setting("defaultPreset", "") || "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function checkHelper() {
    helperCheck.command = ["bash", "-c", "command -v hyprflow >/dev/null 2>&1 && printf ready || printf missing"]
    helperCheck.running = true
  }

  function refreshList() {
    if (!helperInstalled || listProcess.running) return
    listProcess.command = ["hyprflow", "list"]
    listProcess.running = true
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var current = root.settings || ({})
    for (var existing in current) if (existing !== "id") entry[existing] = current[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setDefaultPreset(name) {
    persistSettings({ defaultPreset: String(name || "") })
    statusText = name ? "Default preset set to '" + name + "'." : "Default preset cleared."
  }

  function openHelperInstaller() {
    if (busy || helperInstalled) return
    installingHelper = true
    busy = true
    statusText = "Opening the installer terminal…"
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "omarchy-pkg-aur-add",
      "hyprflow"
    ])
    installPoll.start()
  }

  function normalizeName(value) {
    var clean = String(value || "").trim().toLowerCase()
    clean = clean.replace(/[^a-z0-9._-]+/g, "-")
    clean = clean.replace(/^-+|-+$/g, "")
    return clean === "" ? "workspace" : clean
  }

  function runOperation(kind, name) {
    if (busy) return
    if (!helperInstalled) return

    operationKind = kind
    busy = true
    statusText = "Working…"

    if (kind === "save") {
      operationProcess.command = ["hyprflow", "save", normalizeName(name), "--force"]
    } else if (kind === "restore") {
      operationProcess.command = ["hyprflow", "restore", name]
    } else if (kind === "replace") {
      operationProcess.command = [
        "bash", "-c",
        "set -e; omarchy hyprland window close all; sleep 1; hyprflow restore \"$1\"",
        "deskloom", name
      ]
    } else if (kind === "delete") {
      operationProcess.command = ["hyprflow", "delete", name]
    } else {
      busy = false
      return
    }

    operationProcess.running = true
  }

  function parseList(output) {
    var next = []
    var lines = String(output || "").split("\n")
    var rowPattern = /^\s*(.*?)\s+—\s+(\d+)\s+windows?\s+\(([^)]+)\)(.*)$/
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var match = line.match(rowPattern)
      if (!match) continue
      next.push({
        name: match[1].trim(),
        windows: Number(match[2]),
        created: match[3].trim(),
        automatic: match[4].indexOf("[auto]") !== -1
      })
    }
    snapshots = next
  }

  function operationSummary() {
    var output = String(operationOutput.text || "").trim()
    var error = String(operationError.text || "").trim()
    var source = output !== "" ? output : error
    var firstLine = source.split("\n")[0].trim()
    return firstLine !== "" ? firstLine : "Done"
  }

  Component.onCompleted: checkHelper()

  Timer {
    id: installPoll
    interval: 1000
    repeat: true
    onTriggered: root.checkHelper()
  }

  Process {
    id: helperCheck
    stdout: StdioCollector {
      id: helperOutput
      waitForEnd: true
    }
    onExited: function() {
      root.helperInstalled = String(helperOutput.text || "").trim() === "ready"
      if (root.helperInstalled) {
        if (root.installingHelper) {
          root.installingHelper = false
          root.busy = false
          root.statusText = "hyprflow is ready."
          installPoll.stop()
        }
        root.refreshList()
      }
    }
  }

  Process {
    id: listProcess
    stdout: StdioCollector {
      id: listOutput
      waitForEnd: true
    }
    onExited: root.parseList(listOutput.text)
  }

  Process {
    id: operationProcess
    stdout: StdioCollector {
      id: operationOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: operationError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var kind = root.operationKind
      root.busy = false
      if (exitCode === 0) {
        root.statusText = root.operationSummary()
        root.pendingDeleteName = ""
        root.pendingReplaceName = ""
        root.refreshList()
      } else {
        root.statusText = root.operationSummary()
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "⧉"
    active: root.opened
    tooltipText: "Deskloom workspace snapshots"
    onPressed: root.toggle()
  }

  PopupCard {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(390))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Column {
          width: parent.width - countBadge.width - settingsButton.width - Style.space(16)
          spacing: Style.space(2)

          Text {
            text: "Deskloom"
            color: root.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            text: root.helperInstalled
              ? "Named workspace snapshots"
              : "Needs the hyprflow helper"
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Button {
          id: settingsButton
          text: root.settingsOpen ? "Snapshots" : "Settings"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(5)
          bordered: true
          onClicked: {
            root.settingsOpen = !root.settingsOpen
            root.pendingDeleteName = ""
            root.pendingReplaceName = ""
            if (!root.settingsOpen) root.refreshList()
          }
        }

        BorderSurface {
          id: countBadge
          width: Style.space(34)
          height: Style.space(28)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          Text {
            anchors.centerIn: parent
            text: root.snapshots.length
            color: root.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
      }

      Text {
        width: parent.width
        text: root.statusText
        color: root.statusText.indexOf("failed") >= 0 ? root.urgent : root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        visible: text !== ""
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.helperInstalled

        Text {
          width: parent.width
          text: "Deskloom uses hyprflow to capture window positions, workspaces, monitors, and app launch commands."
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          width: parent.width
          text: root.busy ? "Installing…" : "Install hyprflow from AUR"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          enabled: !root.busy
          onClicked: root.openHelperInstaller()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.helperInstalled && !root.settingsOpen

        Text {
          text: "SAVE SNAPSHOT"
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          BorderSurface {
            width: parent.width - saveButton.width - Style.space(6)
            height: saveButton.height
            color: root.surface
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            radius: Style.cornerRadius

            TextInput {
              id: nameInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(9)
              anchors.rightMargin: Style.space(9)
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              selectionColor: root.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              text: root.saveName
              onTextChanged: root.saveName = text
              Keys.onReturnPressed: root.runOperation("save", text)
            }
          }

          Button {
            id: saveButton
            text: "Save"
            foreground: root.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            enabled: !root.busy && root.normalizeName(root.saveName) !== ""
            onClicked: root.runOperation("save", root.saveName)
          }
        }
      }

      PanelSeparator { foreground: root.foreground; visible: root.helperInstalled && !root.settingsOpen }

      Text {
        text: "SAVED SNAPSHOTS"
        color: root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        visible: root.helperInstalled && !root.settingsOpen
      }

      Text {
        width: parent.width
        text: root.snapshots.length === 0 ? "No snapshots yet. Save the workspace you are in now." : ""
        color: root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        visible: root.helperInstalled && !root.settingsOpen && root.snapshots.length === 0
      }

      ListView {
        id: snapshotList
        width: parent.width
        height: Math.min(contentHeight, Style.space(300))
        model: root.snapshots
        spacing: Style.space(6)
        clip: true
        interactive: contentHeight > height
        visible: root.helperInstalled && !root.settingsOpen

        delegate: Item {
          required property var modelData
          width: snapshotList.width
          height: Style.space(58)

          BorderSurface {
            anchors.fill: parent
            color: root.surface
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            radius: Style.cornerRadius
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(9)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(5)

            Column {
              width: parent.width - actionRow.width - Style.space(5)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: modelData.name
                color: root.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: modelData.windows + " window" + (modelData.windows === 1 ? "" : "s")
                  + "  ·  " + modelData.created + (modelData.automatic ? "  ·  auto" : "")
                color: root.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: actionRow
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Button {
                text: "Open"
                foreground: root.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: !root.busy
                tooltipText: "Restore without closing current windows"
                onClicked: root.runOperation("restore", modelData.name)
              }

              Button {
                text: root.pendingReplaceName === modelData.name ? "Sure?" : "Replace"
                foreground: root.pendingReplaceName === modelData.name ? root.urgent : root.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: !root.busy
                tooltipText: "Close current windows, then restore this snapshot"
                onClicked: {
                  if (root.pendingReplaceName === modelData.name)
                    root.runOperation("replace", modelData.name)
                  else {
                    root.pendingReplaceName = modelData.name
                    root.pendingDeleteName = ""
                    root.statusText = "Click Replace again to close current windows."
                  }
                }
              }

              Button {
                text: root.pendingDeleteName === modelData.name ? "Sure?" : "Delete"
                foreground: root.pendingDeleteName === modelData.name ? root.urgent : root.dim
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: !root.busy
                tooltipText: "Delete this saved snapshot"
                onClicked: {
                  if (root.pendingDeleteName === modelData.name)
                    root.runOperation("delete", modelData.name)
                  else {
                    root.pendingDeleteName = modelData.name
                    root.pendingReplaceName = ""
                    root.statusText = "Click Delete again to remove this snapshot."
                  }
                }
              }
            }
          }
        }
      }

      Column {
        id: settingsColumn
        width: parent.width
        spacing: Style.space(10)
        visible: root.settingsOpen

        Text {
          text: "SETTINGS"
          color: root.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          width: parent.width
          text: root.startOnLogin ? "✓  Start on login" : "□  Start on login"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          leftAlign: true
          bordered: true
          active: root.startOnLogin
          enabled: !root.busy
          onClicked: root.persistSettings({ startOnLogin: !root.startOnLogin })
        }

        Text {
          width: parent.width
          text: "Restore the selected default preset a few seconds after Omarchy starts."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          text: "DEFAULT PRESET"
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.defaultPreset === ""
            ? "None selected"
            : "Current: " + root.defaultPreset
          color: root.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          text: root.helperInstalled
            ? (root.snapshots.length === 0 ? "Save a snapshot first." : "Choose which snapshot should open at login.")
            : "Install hyprflow first to choose a preset."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        ListView {
          id: defaultPresetList
          width: parent.width
          height: Math.min(contentHeight, Style.space(220))
          model: root.snapshots
          spacing: Style.space(4)
          clip: true
          interactive: contentHeight > height

          delegate: Button {
            required property var modelData
            width: defaultPresetList.width
            text: modelData.name === root.defaultPreset ? "✓  " + modelData.name : "     " + modelData.name
            foreground: root.foreground
            fontFamily: root.bar.fontFamily
            leftAlign: true
            bordered: true
            active: modelData.name === root.defaultPreset
            enabled: !root.busy
            onClicked: root.setDefaultPreset(modelData.name)
          }
        }

        Button {
          width: parent.width
          text: "Clear default preset"
          foreground: root.dim
          fontFamily: root.bar.fontFamily
          bordered: true
          enabled: !root.busy && root.defaultPreset !== ""
          onClicked: root.setDefaultPreset("")
        }

        PanelSeparator { foreground: root.foreground }

        Button {
          width: parent.width
          text: root.busy ? "Working…" : "Refresh snapshots"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          enabled: !root.busy && root.helperInstalled
          bordered: true
          onClicked: root.refreshList()
        }

        Text {
          width: parent.width
          text: "Deskloom also refreshes automatically whenever this panel opens."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.checkHelper()
      Qt.callLater(function() {
        if (root.opened && root.helperInstalled) root.refreshList()
      })
    }
  }
}
