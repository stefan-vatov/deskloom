import QtQuick
// Test double for shell-only surface and hover state. No compositor or IPC.
Item {
  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property bool containsMouse: false
  property string triggerMode: "click"
  property int contentWidth: 410
  property int contentHeight: 400
  property real availableCardHeight: 800
  property real verticalContentInset: 0
  function fittedContentWidth(value) { return value }
  function fittedContentHeight(value) { return value }
  width: contentWidth
  height: contentHeight
  visible: open
}
