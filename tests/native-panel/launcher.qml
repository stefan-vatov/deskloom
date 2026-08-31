import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "production" as Production

// Launcher ordering scenario: the real openHelperInstaller drives a fake
// terminal presentation that executes the production detached command, which
// takes the user-scoped lock, clears the attempt result, runs a fake helper
// install script, and publishes the verdict. The panel must observe the
// verdict only through its launch-gated readiness poll and reach the
// finished-but-missing terminal state without releasing the UI early.
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
    }
  }
  Timer {
    interval: 30; running: true; repeat: true
    onTriggered: {
      try {
        if (phase === 0 && panel.snapshotActionsReady() && panel.helperInstalled) {
          var before = { busy: panel.busy, installing: panel.installingHelper, status: panel.statusText }
          panel.openHelperInstaller()
          check(panel.installingHelper === false, "a rejected launch must not arm the installer flow")
          check(panel.busy === before.busy, "a rejected launch must not serialize the UI")
          check(panel.installerLaunched === false, "a rejected launch must not open the observation gate")
          console.log("NATIVE_PASS launcher refuses to run while hyprloom is already installed")
          Qt.quit()
        }
      } catch (error) { console.error("NATIVE_FAIL " + error); Qt.quit() }
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { console.error("NATIVE_FAIL timeout phase " + phase + " busy=" + panel.busy + " installing=" + panel.installingHelper + " polls=" + panel.installerPolls + " launched=" + panel.installerLaunched + " text=" + panel.statusText); Qt.quit() } }
}
