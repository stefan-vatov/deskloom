import QtQuick
import QtQuick.Controls as Controls
Controls.Button {
  property string fontFamily: "DejaVu Sans Mono"
  property real fontSize: 12
  font.family: fontFamily
  font.pixelSize: fontSize
}
