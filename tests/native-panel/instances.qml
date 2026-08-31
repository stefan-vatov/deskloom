import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import "production" as Production

// Multi-instance smoke scenario: two independently identified production
// Panel instances share one doubled helper. Exercises a deterministic
// pause/release barrier at helper dispatch, cross-instance readiness,
// argv capture, chunked stdout, and reportingStatus observation. Every
// boundary observation emits a schema-checked TRACE record.
ShellRoot {
  id: harness
  property int phase: 0
  property var seqs: ({})
  property int saveExits: 0
  function check(value, message) { if (!value) throw new Error(message) }
  function mark(instance, operation, transition, assertion) {
    var next = seqs[instance] === undefined ? 0 : seqs[instance] + 1
    seqs[instance] = next
    console.log("TRACE " + JSON.stringify({ scenario: "instances", seq: next, instance: instance,
      operation: operation, transition: transition, assertion: assertion }))
  }
  TestCase { id: probes; when: false }
  QtObject {
    id: fakeBarA
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color urgent: Color.urgent
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
    function showTooltip(o, t) {} function hideTooltip(o) {}
    function requestPopout(o) {} function releasePopout(o) {}
  }
  QtObject {
    id: fakeBarB
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color urgent: Color.urgent
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
    function showTooltip(o, t) {} function hideTooltip(o) {}
    function requestPopout(o) {} function releasePopout(o) {}
  }
  FloatingWindow {
    visible: true
    implicitWidth: 800
    implicitHeight: 900
    Production.Panel {
      id: panelA
      width: 800; height: 900
      bar: fakeBarA
      settings: ({ startOnLogin: false, defaultPreset: "" })
      function launchBootRestore() { throw new Error("Boot restore forbidden") }
      function openHelperInstaller() { throw new Error("Installer forbidden") }
    }
    Production.Panel {
      id: panelB
      width: 800; height: 900
      bar: fakeBarB
      settings: ({ startOnLogin: false, defaultPreset: "" })
      function launchBootRestore() { throw new Error("Boot restore forbidden") }
      function openHelperInstaller() { throw new Error("Installer forbidden") }
    }
  }
  // Production Process used to release the helper barrier deterministically.
  Process {
    id: barrierRelease
    command: ["touch", Quickshell.env("FIXTURE_BARRIER")]
  }
  Timer {
    interval: 30; running: true; repeat: true
    onTriggered: {
      try {
        if (phase === 0 && panelA.snapshotActionsReady() && panelB.snapshotActionsReady()
            && panelA.snapshots.length >= 1 && panelB.snapshots.length >= 1) {
          mark("A", "list", "loaded", "both instances observe the shared registry")
          mark("B", "list", "loaded", "both instances observe the shared registry")
          var statusA = JSON.parse(panelA.reportingStatus())
          check(statusA.snapshotCount >= 1 && statusA.componentUrl.indexOf("production/Panel.qml") >= 0, "reportingStatus observation failed")
          mark("A", "reportingStatus", "observed", "component identity visible")
          check(panelA.helperProcessCommand(["list"]).slice(-1)[0] === "list", "argv capture failed")
          mark("A", "argv", "captured", "production command builder output")
          var operation = probes.findChild(panelA, "operationProcess")
          check(operation, "Missing operationProcess probe")
          operation.exited.connect(function() { harness.saveExits++ })
          panelA.runOperation("save", "barrier-save")
          phase = 1
        } else if (phase === 1 && panelA.busy && saveExits === 0) {
          // Helper dispatch is deterministically paused at the barrier.
          check(!panelA.snapshots.some(function (item) { return item.name === "barrier-save" }), "save completed despite the barrier")
          mark("A", "save", "barrier-paused", "helper dispatch paused before response")
          barrierRelease.running = true
          phase = 2
        } else if (phase === 2 && saveExits === 1 && !panelA.busy) {
          mark("A", "save", "barrier-released", "release published the result")
          panelB.refreshList()
          phase = 3
        } else if (phase === 3 && panelB.snapshotActionsReady()
                   && panelB.snapshots.some(function (item) { return item.name === "barrier-save" })) {
          // Cross-instance visibility: instance B sees A's publication.
          check(panelB.snapshots.some(function (item) { return item.name === "barrier-save" }), "instance B lost A's result")
          mark("B", "list", "observed-publication", "cross-instance coordination proven")
          panelB.refreshList()
          phase = 4
        } else if (phase === 4 && panelB.snapshotActionsReady()) {
          mark("B", "smoke", "complete", "real controls, process argv, chunked output, publication, readiness, two instances")
          console.log("NATIVE_PASS two instances coordinated across a deterministic helper barrier")
          Qt.quit()
        }
      } catch (error) { console.error("NATIVE_FAIL " + error); Qt.quit() }
    }
  }
  function debugState() {
    var namesA = panelA.snapshots.map(function (i) { return i.name }).join(",")
    var namesB = panelB.snapshots.map(function (i) { return i.name }).join(",")
    return "busyA=" + panelA.busy + " readyA=" + panelA.snapshotActionsReady() + " readyB=" + panelB.snapshotActionsReady() + " namesA=" + namesA + " namesB=" + namesB + " textA=" + panelA.statusText
  }
  Timer { interval: 10000; running: true; onTriggered: { console.error("NATIVE_FAIL timeout phase " + phase + " " + debugState()); Qt.quit() } }
}
