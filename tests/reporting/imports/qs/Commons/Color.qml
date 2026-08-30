pragma Singleton
import QtQuick
QtObject {
  readonly property color foreground: "#eeeeee"
  readonly property color urgent: "#ff9c9c"
  readonly property color accent: "#abcdef"
  readonly property color background: "#202020"
  readonly property var shellValues: ({})
  readonly property QtObject popups: QtObject {
    readonly property color background: "#202020"
    readonly property color border: "#eeeeee"
  }
}
