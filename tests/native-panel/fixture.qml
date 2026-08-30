import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "production" as Production

ShellRoot {
  id: harness
  property int phase: 0
  property var reportPopup
  property var lastButton
  property int exits: 0
  property int streamsFinished: 0
  property bool streamOrderOk: true
  readonly property bool realCli: Quickshell.env("FIXTURE_REAL_CLI") === "1"
  function check(value, message) { if (!value) throw new Error(message) }
  function status() {
    var raw = panel.reportingStatus()
    var value = JSON.parse(raw)
    check(value.version === panel.pluginVersion && value.helperVersion === panel.helperVersion && value.sourceCommit === panel.helperSourceCommit, "Wrong loaded metadata")
    check(value.componentUrl.endsWith("/production/Panel.qml") && value.monitor === panel.reportScreenName, "Wrong component identity")
    check(raw.indexOf("Existing row") < 0 && raw.indexOf("New row") < 0, "Status leaked titles")
    return value
  }
  TestCase { id: probes; when: false }
  QtObject {
    id: fakeBar
    property string position: "top"
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color urgent: Color.urgent
    property var activePopout: null
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
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
        if (phase === 0 && panel.snapshotActionsReady() && panel.snapshots.length === 1) {
          reportPopup = probes.findChild(panel, "restoreReportPopup")
          lastButton = probes.findChild(panel, "lastRestoreButton")
          var operation = probes.findChild(panel, "operationProcess")
          check(reportPopup && lastButton && operation, "Missing full Panel probes")
          operation.stdout.streamFinished.connect(function() { harness.streamsFinished++ })
          operation.stderr.streamFinished.connect(function() { harness.streamsFinished++ })
          operation.exited.connect(function() {
            harness.exits++
            if (harness.streamsFinished !== harness.exits * 2) harness.streamOrderOk = false
          })
          check(!status().hasReport && status().counts === null, "Initial report should be empty")
          check(status().snapshotCount === 1 && status().snapshotsLoaded && !status().snapshotListFailed, "Initial list was not loaded")
          panel.open()
          panel.runOperation(realCli ? "save" : "restore", realCli ? "Native Save" : "fixture")
          phase = realCli ? 7 : 1
        } else if (phase === 1 && exits === 1 && !panel.busy) {
          check(reportPopup.open && !panel.opened, "Report did not take over popup")
          check(reportPopup.report.available, "Collector output unavailable at exit")
          check(streamOrderOk, "Process exited before collectors finished")
          var success = status()
          check(success.hasReport && success.reportOpen && success.reportAvailable && success.counts.unchanged === 1 && success.counts.launched === 1, "Wrong success status")
          var rows = reportPopup.report.groups[0].windows
          check(rows.length === 2 && rows[0].title === "Existing row" && rows[1].title === "New row", "Lost report rows")
          panel.open()
          phase = 2
        } else if (phase === 2 && panel.snapshotActionsReady()) {
          check(lastButton.visible && !reportPopup.open, "Last restore not retained on reopen")
          lastButton.clicked()
          check(reportPopup.open && reportPopup.report.groups[0].windows.length === 2, "Reopen lost report")
          panel.runOperation("restore", "failure")
          phase = 3
        } else if (phase === 3 && exits === 2 && !panel.busy) {
          check(reportPopup.open && !reportPopup.report.available, "Failure did not present unavailable report")
          var failure = status()
          check(streamOrderOk && failure.hasReport && failure.reportOpen && !failure.reportAvailable && failure.counts === null, "Wrong failure status or collector ordering")
          panel.open()
          check(lastButton.visible, "Failure report not retained")
          panel.runOperation("save", "Native Save")
          phase = 4
        } else if (phase === 4 && exits === 3 && panel.snapshotActionsReady()) {
          check(panel.snapshots.length === 2 && panel.snapshots.some(function(item) { return item.name === "native-save" }), "Successful save missing from refreshed list")
          panel.runOperation("save", "failure")
          phase = 5
        } else if (phase === 5 && exits === 4 && !panel.busy) {
          check(panel.snapshots.length === 2, "Failed save hid existing snapshots")
          check(panel.statusText.endsWith("FINAL DIAGNOSTIC LINE"), "Save error lost later lines")
          var scroller = probes.findChild(panel, "statusScroller")
          var message = probes.findChild(panel, "statusMessage")
          check(scroller && message && message.text.endsWith("FINAL DIAGNOSTIC LINE"), "Full diagnostic missing from UI")
          check(message.readOnly && message.selectByMouse && message.wrapMode === TextEdit.Wrap, "Error must wrap and be selectable")
          phase = 6
        } else if (phase === 6) {
          var scroller = probes.findChild(panel, "statusScroller")
          check(scroller.contentHeight > scroller.height && scroller.height > 0, "Long diagnostic cannot scroll")
          scroller.contentY = scroller.contentHeight - scroller.height
          check(scroller.contentY > 0, "Cannot reach diagnostic tail")
          console.log("NATIVE_PASS full Panel production commands: list, save, failure details, restore, Last restore")
          Qt.quit()
        } else if (phase === 7 && exits === 1 && panel.snapshotActionsReady()) {
          check(panel.snapshots.length === 2 && panel.snapshots.some(function(item) { return item.name === "native-save" }), "Real CLI save missing from list: " + panel.statusText)
          panel.runOperation("restore", "fixture")
          phase = 8
        } else if (phase === 8 && exits === 2 && !panel.busy) {
          check(reportPopup.open && reportPopup.report.available, "Real CLI report unavailable")
          check(reportPopup.report.counts.unchanged === 1 && reportPopup.report.counts.launched === 0, "Real CLI existing window outcome incorrect")
          check(reportPopup.report.groups[0].windows[0].title === "Editor — native fixture", "Real CLI report row missing")
          console.log("NATIVE_PASS full Panel with installed CLI: old preset listed, save persisted, existing window reported")
          Qt.quit()
        }
      } catch (error) { console.error("NATIVE_FAIL " + error); Qt.quit() }
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { console.error("NATIVE_FAIL timeout phase " + phase + " " + panel.statusText); Qt.quit() } }
}
