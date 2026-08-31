import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "production" as Production

// Destructive-consent scenario: the real Panel with real Replace/Delete
// buttons against a fake helper. Proves a confirmed destructive operation
// consumes its consent at the accepted launch boundary, a failed attempt
// leaves no reusable token across a view reopen, and unrelated input can
// neither fire nor inherit a destructive command.
ShellRoot {
  id: harness
  property int phase: 0
  property int exits: 0
  function check(value, message) { if (!value) throw new Error(message) }
  function destructiveRows() {
    return panel.snapshots.filter(function (item) { return item.name.indexOf("destructive-") === 0 })
  }
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
        if (phase === 0 && panel.snapshotActionsReady()
            && panel.snapshots.some(function (item) { return item.name === "fixture" })) {
          panel.open()
          phase = 1
        } else if (phase === 1 && panel.snapshotActionsReady() && !panel.busy) {
          var operation = probes.findChild(panel, "operationProcess")
          check(operation, "Missing operationProcess probe")
          operation.exited.connect(function() { harness.exits++ })
          // The delegate buttons live in a separate popup window that
          // offscreen rendering does not instantiate; the buttons' onClicked
          // handlers delegate to these production functions, which is the
          // control path driven here.
          panel.requestReplace("fixture")
          check(panel.pendingReplaceName === "fixture" && panel.pendingDeleteName === "", "Arming failed")
          phase = 2
        } else if (phase === 2 && panel.snapshotActionsReady()
                   && panel.pendingReplaceName === "fixture") {
          // Confirming click: fired exactly once; the deferred launch
          // consumes consent before the next input can be processed.
          panel.requestReplace("fixture")
          phase = 3
        } else if (phase === 3 && exits === 1 && !panel.busy && panel.snapshotActionsReady()) {
          check(panel.pendingReplaceName === "" && panel.pendingDeleteName === "", "Accepted launch must consume consent")
          phase = 4
        } else if (phase === 4 && panel.snapshotActionsReady() && !panel.busy) {
          // open() runs checkHelper, which briefly blocks readiness; arm on
          // the first tick where the panel accepts input.
          panel.requestReplace("failure")
          if (panel.pendingReplaceName === "failure") phase = 5
        } else if (phase === 5 && panel.snapshotActionsReady()
                   && panel.pendingReplaceName === "failure") {
          panel.requestReplace("failure")
          phase = 6
        } else if (phase === 6 && exits === 2 && !panel.busy && panel.snapshotActionsReady()) {
          if (!destructiveRows().some(function (item) { return item.name === "destructive-2" })) {
            // A failed replace does not auto-refresh; poll the counter.
            panel.refreshList()
          } else {
            check(destructiveRows().length === 1, "Two confirmations must yield exactly two destructive invocations, got " + destructiveRows().map(function (r) { return r.name }))
            panel.requestReplace("failure")
            check(panel.pendingReplaceName === "failure", "Arm after failure must require confirmation")
            panel.runOperation("save", "consent-save")
            check(panel.pendingReplaceName === "", "Unrelated accepted input must clear reusable consent")
            phase = 7
          }
        } else if (phase === 7 && exits === 3 && !panel.busy && panel.snapshotActionsReady()) {
          if (!panel.snapshots.some(function (item) { return item.name === "consent-save" })) {
            // The exit-connection order can beat the Panel's own refresh.
            panel.refreshList()
          } else {
            check(panel.pendingReplaceName === "", "Failed intervening input preserves no stale token")
            panel.requestDelete("fixture")
            check(panel.pendingDeleteName === "fixture" && panel.pendingReplaceName === "", "Delete arming failed")
            phase = 8
          }
        } else if (phase === 8 && panel.snapshotActionsReady()
                   && panel.pendingDeleteName === "fixture") {
          panel.requestDelete("fixture")
          phase = 9
        } else if (phase === 9 && exits === 4 && !panel.busy && panel.snapshotActionsReady()) {
          if (!panel.snapshots.some(function (item) { return item.name === "destructive-3" })) {
            // The exit-connection order can beat the Panel's own refresh.
            panel.refreshList()
          } else {
            check(!panel.snapshots.some(function (item) { return item.name === "fixture" }), "Deleted snapshot still listed")
            check(panel.pendingDeleteName === "" && panel.pendingReplaceName === "", "Terminal state must be consent-free")
            console.log("NATIVE_PASS destructive consent consumed at launch; failures leave no reusable token")
            Qt.quit()
          }
        }
      } catch (error) { console.error("NATIVE_FAIL " + error); Qt.quit() }
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { console.error("NATIVE_FAIL timeout phase " + phase + " helper=" + panel.helperInstalled + " busy=" + panel.busy + " snaps=" + panel.snapshots.length + " opened=" + panel.opened + " failed=" + panel.snapshotListFailed + " loaded=" + panel.snapshotsLoaded + " text=" + panel.statusText); Qt.quit() } }
}
