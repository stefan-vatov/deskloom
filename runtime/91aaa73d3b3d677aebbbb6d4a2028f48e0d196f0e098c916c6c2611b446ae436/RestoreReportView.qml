import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui
import "RestoreReport.js" as ReportModel

// Presentation only: never instantiate Deskloom's operational Panel here.
Column {
  id: root
  property var report: null
  property real maxListHeight: Style.space(300)
  property string fontFamily: Style.font.family
  property color canvasColor: Color.popups.background
  readonly property real headerHeight: heading.implicitHeight + spacing
  readonly property var summaryEntries: {
    if (!root.report || !root.report.counts) return []
    var entries = []
    var statuses = ["unchanged", "moved", "launched", "extra", "skipped", "failed"]
    var labels = root.report.dryRun ? ReportModel.plannedLabels : ReportModel.labels
    for (var i = 0; i < statuses.length; i++) {
      var status = statuses[i]
      var count = root.report.counts[status === "extra" ? "extras" : status]
      if (count > 0) entries.push({ status: status, label: count + " " + labels[status] })
    }
    return entries
  }
  signal closeRequested
  width: Style.space(390)
  spacing: Style.space(10)

  function luminance(c: color): real {
    function linear(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
  }
  function contrast(a: color, b: color): real {
    var x = luminance(a), y = luminance(b)
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
  }
  function mix(a: color, b: color, amount: real): color {
    return Qt.rgba(a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount, 1)
  }
  function readableTone(base: color): color {
    var target = luminance(root.canvasColor) > 0.179 ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
    for (var step = 0; step <= 20; step++) {
      var ink = mix(base, target, step / 20)
      if (contrast(ink, root.canvasColor) >= 5.5) return ink
    }
    return target
  }
  function outcomeColor(status): color {
    switch (status) {
      case "unchanged": return readableTone("#89b4fa")
      case "launched": return readableTone("#a6e3a1")
      case "moved": return readableTone("#f9e2af")
      case "skipped": return readableTone("#cba6f7")
      case "failed": return readableTone(Color.urgent)
      default: return readableTone(Color.foreground)
    }
  }
  function badgeFill(ink: color): color {
    var tinted = mix(root.canvasColor, ink, 0.10)
    return contrast(ink, tinted) >= 4.5 ? tinted : root.canvasColor
  }

  component OutcomeBadge: Rectangle {
    id: badge
    property alias label: badgeLabel.text
    property string labelObjectName: ""
    property color ink: Color.foreground
    implicitWidth: badgeLabel.implicitWidth + Style.space(14)
    implicitHeight: badgeLabel.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: root.badgeFill(ink)
    Text {
      id: badgeLabel
      objectName: badge.labelObjectName
      x: Style.space(7)
      y: Style.space(4)
      width: Math.max(0, badge.width - Style.space(14))
      textFormat: Text.PlainText
      color: badge.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }
  }

  Row {
    id: heading
    width: parent.width
    spacing: Style.space(8)
    Text {
      width: Math.max(0, parent.width - closeButton.width - parent.spacing)
      text: root.report ? root.report.title : "Report unavailable"
      textFormat: Text.PlainText
      color: root.report && root.report.hasIssues ? Color.urgent : Color.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      wrapMode: Text.Wrap
    }
    Button {
      id: closeButton
      objectName: "reportCloseButton"
      text: "Close"
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.closeRequested()
    }
  }
  Flickable {
    id: scroller
    objectName: "reportScroller"
    width: parent.width
    height: Math.min(contentHeight, Math.max(0, root.maxListHeight))
    contentWidth: width
    contentHeight: bodyColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      policy: Controls.ScrollBar.AsNeeded
    }
    Column {
      id: bodyColumn
      width: Math.max(0, scroller.width - Style.space(12))
      spacing: Style.space(10)
      Text {
        width: parent.width
        visible: text.length > 0
        text: root.report ? root.report.session : ""
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        visible: root.summaryEntries.length === 0
        text: root.report ? root.report.summary : "No restore report is available."
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
      Flow {
        id: summaryFlow
        width: parent.width
        spacing: Style.space(6)
        visible: root.summaryEntries.length > 0
        Repeater {
          objectName: "reportSummary"
          model: root.summaryEntries
          OutcomeBadge {
            required property var modelData
            label: modelData.label
            ink: root.outcomeColor(modelData.status)
            width: Math.min(implicitWidth, summaryFlow.width)
          }
        }
      }
      Text {
        objectName: "reportDetail"
        width: parent.width
        visible: text.length > 0
        text: root.report ? root.report.detail : ""
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
      Column {
        id: groupsColumn
        width: parent.width
        spacing: Style.space(16)
        Repeater {
          model: root.report ? root.report.groups : []
          Column {
            required property var modelData
            width: groupsColumn.width
            spacing: Style.space(8)
            Text {
              width: parent.width
              text: parent.modelData.label
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.Wrap
            }
            Repeater {
              model: parent.modelData.windows
              Column {
                id: windowRow
                required property var modelData
                width: parent.width
                spacing: Style.space(2)
                Text {
                  objectName: "reportWindowTitle"
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  width: parent.width
                  text: parent.modelData.title
                  textFormat: Text.PlainText
                  color: Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  OutcomeBadge {
                    id: statusBadge
                    labelObjectName: "reportWindowStatus"
                    label: windowRow.modelData.label
                    ink: root.outcomeColor(windowRow.modelData.status)
                    width: Math.min(implicitWidth, parent.width * 0.7)
                  }
                  Text {
                    objectName: "reportWindowClass"
                    width: Math.max(0, parent.width - statusBadge.width - parent.spacing)
                    anchors.verticalCenter: parent.verticalCenter
                    text: windowRow.modelData.className
                    textFormat: Text.PlainText
                    color: Color.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
                Text {
                  width: parent.width
                  visible: text.length > 0
                  text: parent.modelData.message
                  textFormat: Text.PlainText
                  color: Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }
      }
    }
  }
  onReportChanged: scroller.contentY = 0
}
