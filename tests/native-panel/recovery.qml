import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "production" as Production

// Recovery diagnostic scenario: startup recovery receives chunked, delayed,
// multiline stderr through the real Quickshell Process boundary and the full
// text must reach the selectable, scrollable status surface.
ShellRoot {
  id: harness
  property int phase: 0
  function check(value, message) { if (!value) throw new Error(message) }
  TestCase { id: probes; when: false }
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
  FloatingWindow {
    visible: true
    implicitWidth: 800
    implicitHeight: 900
    Production.Panel {
      id: panel
      width: 800; height: 900
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
        if (phase === 0 && !panel.busy && panel.snapshotActionsReady()
            && panel.statusText.indexOf("manual step: hyprloom restore autosave-keep") >= 0) {
          check(panel.statusText.indexOf("startup recovery step failed") >= 0, "Lost the first stderr chunk")
          check(panel.statusText.indexOf("safety snapshot: autosave-keep") >= 0, "Lost the delayed stderr chunk")
          check(panel.statusText.indexOf("Startup recovery failed") >= 0, "Missing failure context")
          var scroller = probes.findChild(panel, "statusScroller")
          var message = probes.findChild(panel, "statusMessage")
          check(scroller && message, "Missing status probes")
          check(message.readOnly && message.selectByMouse && message.wrapMode === TextEdit.Wrap, "Diagnostic must be selectable and wrapped")
          check(scroller.contentHeight > scroller.height, "Long diagnostic cannot scroll")
          scroller.contentY = scroller.contentHeight - scroller.height
          check(scroller.contentY > 0, "Cannot reach the diagnostic tail")
          console.log("NATIVE_PASS recovery diagnostics preserved across chunked delayed stderr")
          Qt.quit()
        }
      } catch (error) { console.error("NATIVE_FAIL " + error); Qt.quit() }
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { console.error("NATIVE_FAIL timeout phase " + phase + " busy=" + panel.busy + " ready=" + panel.snapshotActionsReady() + " text=" + panel.statusText); Qt.quit() } }
}
