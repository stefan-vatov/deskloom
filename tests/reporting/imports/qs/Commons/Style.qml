pragma Singleton
import QtQuick
QtObject {
  function space(value) { return value }
  readonly property int gapsOut: 8
  readonly property int cornerRadius: 8
  readonly property QtObject spacing: QtObject { readonly property int popupPadding: 12 }
  readonly property QtObject font: QtObject {
    readonly property string family: "DejaVu Sans Mono"
    readonly property int subtitle: 16
    readonly property int body: 14
    readonly property int caption: 12
  }
}
