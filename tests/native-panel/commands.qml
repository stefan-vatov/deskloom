import QtQuick
import Quickshell
import qs.Commons
import "production" as Production

ShellRoot {
  QtObject {
    id: fakeBar
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color urgent: Color.urgent
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
  }
  Production.Panel {
    id: panel
    bar: fakeBar
    settings: ({ startOnLogin: false, defaultPreset: "" })
    function checkHelper() {}
  }
  function cases() {
    return [
      { tag: "list", argv: ["list"] },
      { tag: "save", argv: ["save", "cozy-default", "--force"] },
      { tag: "restore", argv: ["restore", "cozy-default", "--reconcile", "--report-json"] },
      { tag: "replace", argv: ["replace", "cozy-default", "--report-json"] },
      { tag: "delete", argv: ["delete", "cozy-default"] },
      { tag: "recover", argv: ["recover"] },
      { tag: "literal", argv: ["save", "quotes ' spaces ; $() <markup> —", ""] }
    ]
  }
  Timer {
    interval: 1; running: true
    onTriggered: {
      try {
        var data = cases()
        for (var i = 0; i < data.length; i++) {
          var command = panel.helperProcessCommand(data[i].argv)
          if (JSON.stringify(command.slice(4)) !== JSON.stringify(data[i].argv))
            throw new Error(data[i].tag + ": expected " + JSON.stringify(data[i].argv) + ", got " + JSON.stringify(command.slice(4)))
        }
        console.log("NATIVE_PASS production command arguments")
      } catch (error) { console.error("NATIVE_FAIL " + error) }
      Qt.quit()
    }
  }
}
