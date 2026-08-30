import QtQuick
import Quickshell
ShellRoot {
  Timer {
    interval: 1; running: true
    onTriggered: {
    var component = Qt.createComponent("file://" + Quickshell.env("FIXTURE_PANEL"), Component.PreferSynchronous)
    if (component.status === Component.Ready) console.log("NATIVE_PASS original Panel compiles")
    else console.error("NATIVE_FAIL original Panel: " + component.errorString())
    Qt.quit()
    }
  }
}
