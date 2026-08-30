import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  Component.onCompleted: Quickshell.watchFiles = false
  property string url: "file://" + Quickshell.env("FIXTURE_DYNAMIC")
  function readRevision() {
    var component = Qt.createComponent(url, Component.PreferSynchronous)
    if (component.status !== Component.Ready) throw new Error(component.errorString())
    var item = component.createObject(root)
    var revision = item.revision
    item.destroy()
    component.destroy()
    return revision
  }
  Timer {
    interval: 1; running: true
    onTriggered: {
      try {
        if (readRevision() !== 1) throw new Error("Initial revision incorrect")
        rewrite.running = true
      } catch (error) { console.error("NATIVE_FAIL cache " + error); Qt.quit() }
    }
  }
  Process {
    id: rewrite
    command: [Quickshell.env("FIXTURE_NODE"), Quickshell.env("FIXTURE_HELPER"), "cache-update"]
    onExited: function(code) {
      if (code !== 0) { console.error("NATIVE_FAIL cache rewrite"); Qt.quit(); return }
      inspect.restart()
    }
  }
  Timer {
    id: inspect
    interval: 1
    onTriggered: {
      try {
        var canClear = typeof Qt.clearComponentCache === "function"
        if (canClear) Qt.clearComponentCache()
        var observed = readRevision()
        if (observed !== 1 && observed !== 2) throw new Error("Unexpected revision")
        url = url.replace("dynamic.qml", "RevisionTwo.qml")
        if (readRevision() !== 2) throw new Error("Changed URL did not load new bytes")
        console.log("NATIVE_PASS cache observation: disk=2 loaded=" + observed + " changedURL=2 Qt.clearComponentCache=" + canClear)
      } catch (error) { console.error("NATIVE_FAIL cache " + error) }
      Qt.quit()
    }
  }
}
