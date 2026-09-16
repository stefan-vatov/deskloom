import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "production" as Production

ShellRoot {
  id: harness
  property int phase: 0
  property var input: null
  property var popup: null
  function check(value, message) { if (!value) throw new Error(message) }
  TestCase {
    id: probes
    parent: harness.input
    when: false
  }
  QtObject {
    id: fakeBar
    property string position: "top"
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color urgent: Color.urgent
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
    property var activePopout: null
    function showTooltip(owner, text) {}
    function hideTooltip(owner) {}
    function requestPopout(owner) {
      if (activePopout && activePopout !== owner) activePopout.close()
      activePopout = owner
    }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
  }
  FloatingWindow {
    visible: true
    implicitWidth: 800
    implicitHeight: 32
    Production.Panel {
      id: panel
      width: 32; height: 32
      bar: fakeBar
      settings: ({ startOnLogin: false, defaultPreset: "" })
      function launchBootRestore() { throw new Error("Boot restore forbidden") }
      function openHelperInstaller() { throw new Error("Installer forbidden") }
    }
  }
  Timer {
    interval: 30; running: true; repeat: true
    onTriggered: {
      try {
        if (phase === 0 && panel.snapshotActionsReady()) {
          input = probes.findChild(panel, "snapshotNameInput")
          popup = probes.findChild(panel, "snapshotPopup")
          check(input && popup, "Missing input probes")
          panel.open()
          phase = 1
        } else if (phase === 1 && panel.snapshotActionsReady()) {
          check(input.visible && input.enabled && !input.readOnly, "Name input is not editable")
          check(input.activeFocus, "Name input has no keyboard focus after opening")
          probes.keyClick(Qt.Key_A, Qt.ControlModifier)
          var name = "Input Save"
          for (var index = 0; index < name.length; index++) probes.keyClick(name[index])
          check(input.text === name && panel.saveName === name, "Typing did not replace the selected name")
          probes.keyClick("x")
          probes.keyClick(Qt.Key_Backspace)
          check(input.text === name && panel.saveName === name, "Backspace did not update the name")
          probes.keyClick(Qt.Key_Return)
          phase = 2
        } else if (phase === 2 && panel.snapshotActionsReady()
                   && panel.snapshots.some(function(row) { return row.name === "input-save" })) {
          check(panel.opened, "Saving unexpectedly closed the editor")
          probes.keyClick(Qt.Key_Escape)
          check(!panel.opened && fakeBar.activePopout === null, "Escape did not dismiss and release the popup")
          // Reopen during the fade-out, before the native window unmaps.
          panel.open()
          phase = 3
        } else if (phase === 3 && panel.snapshotActionsReady()) {
          check(input.activeFocus && input.text === "Input Save", "Reopening lost focus or the draft")
          probes.keyClick("x")
          check(panel.saveName === "Input Savex", "Cannot type after reopening")
          panel.settingsOpen = true
          check(!input.visible, "Settings did not hide the editor")
          panel.settingsOpen = false
          phase = 4
        } else if (phase === 4) {
          check(input.activeFocus, "Returning from Settings did not focus the name")
          input.parent.forceActiveFocus()
          probes.mouseClick(input, input.width / 2, input.height / 2)
          check(input.activeFocus, "Clicking the input did not focus it")
          probes.keyClick(Qt.Key_A, Qt.ControlModifier)
          probes.keyClick("z")
          check(input.text === "z" && panel.saveName === "z", "Cannot type after clicking the input")
          // A native popup dismissal must also close the Panel controller.
          input.Window.window.close()
          phase = 5
        } else if (phase === 5) {
          check(!panel.opened && fakeBar.activePopout === null, "Native dismissal left the panel logically open")
          panel.open()
          phase = 6
        } else if (phase === 6 && panel.snapshotActionsReady()) {
          check(popup.visible && input.activeFocus, "Native dismissal prevented reopening")
          probes.keyClick("x")
          check(panel.saveName === "zx", "Cannot type after native dismissal and reopen")
          panel.close()
          console.log("NATIVE_PASS name typing, editing, Enter save, click focus, Settings, Escape, native dismissal and reopen")
          Qt.quit()
        }
      } catch (error) { console.error("NATIVE_FAIL " + error); Qt.quit() }
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { console.error("NATIVE_FAIL input timeout phase " + phase); Qt.quit() } }
}
