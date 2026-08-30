import QtQuick
import QtTest
import "../.." as Deskloom
import "../../RestoreReport.js" as Model

Item {
  width: 440
  height: 500
  Deskloom.RestoreReportView {
    id: reportView
    width: 420
    report: ({ available: true, title: "Restore complete", session: "work", summary: "1 Found existing",
      detail: "", groups: [{ label: "Workspace 2", windows: [{ title: "Notes", className: "terminal", label: "Found existing", message: "" }] }] })
  }
  TestCase {
    name: "RestoreReportView"
    when: windowShown
    function init() {
      reportView.canvasColor = "#202020"
      reportView.report = ({ available: true, title: "Restore complete", session: "work", summary: "1 Found existing",
        detail: "", groups: [{ label: "Workspace 2", windows: [{ title: "Notes", className: "terminal", label: "Found existing", message: "" }] }] })
    }
    function test_oneRow() {
      tryVerify(function() { return findChild(reportView, "reportWindowTitle") !== null })
      compare(findChild(reportView, "reportWindowTitle").text, "Notes")
      compare(findChild(reportView, "reportWindowTitle").textFormat, Text.PlainText)
    }
    function test_closeButton() {
      var close = findChild(reportView, "reportCloseButton")
      verify(close !== null)
      closeSpy.clear()
      mouseClick(close)
      compare(closeSpy.count, 1)
    }
    function test_detailsAndPlainText() {
      var detail = findChild(reportView, "reportDetail")
      verify(detail !== null)
      compare(detail.textFormat, Text.PlainText)
      compare(findChild(reportView, "reportWindowStatus").text, "Found existing")
      compare(findChild(reportView, "reportWindowClass").text, "terminal")
    }
    function test_longDiagnosticScrolls() {
      reportView.report = Model.parse('', 1, Array(100).join('A diagnostic with <b>plain</b> text. '), 'work')
      var scroll = findChild(reportView, "reportScroller")
      tryVerify(function() { return scroll.contentHeight > scroll.height })
      verify(reportView.height <= reportView.maxListHeight + 100)
    }
    function test_qmlParser() {
      var model = Model.parse(JSON.stringify({ schema_version: 1, operation: 'reconcile', session: 'work', dry_run: false,
        report: { matched: 1, unchanged: 1, moved: 0, launched: 0, extras: 0, skipped: 0, failed: 0,
          windows: [{ workspace: 1, workspace_name: null, class: 'terminal', title: '<b>日本語</b>', status: 'unchanged', match_kind: null, message: null }] }, recovery: null }), 0, '', '')
      reportView.report = model
      compare(model.available, true)
      tryVerify(function() { return findChild(reportView, "reportWindowTitle") !== null })
      compare(findChild(reportView, "reportWindowTitle").text, '<b>日本語</b>')
    }
    function test_longWindowTitleIsBounded() {
      var model = reportView.report
      model.groups[0].windows[0].title = Array(100).join('Long title ')
      model.groups[0].windows[0].className = Array(100).join('long-class-')
      reportView.report = null
      reportView.report = model
      var title = findChild(reportView, "reportWindowTitle")
      tryVerify(function() { return title.truncated })
      compare(title.maximumLineCount, 2)
      compare(findChild(reportView, "reportWindowStatus").maximumLineCount, 2)
    }
    function test_statusColoursAndLabels() {
      var statuses = ["unchanged", "launched", "moved", "extra", "skipped", "failed"]
      var labels = ["Found existing", "Restored", "Adjusted existing", "Left alone", "Skipped", "Failed"]
      var colours = []
      for (var i = 0; i < statuses.length; i++) {
        reportView.report = { title: "Restore complete", session: "work", summary: "", detail: "", groups: [
          { label: "Workspace 2", windows: [{ title: "Notes", className: "terminal", status: statuses[i], label: labels[i], message: "" }] }
        ] }
        verify(waitForPolish(reportView))
        var label = findChild(reportView, "reportWindowStatus")
        compare(label.text, labels[i])
        verify(colours.indexOf(String(label.color)) === -1, "Each outcome should have a distinct colour")
        colours.push(String(label.color))
      }
    }
    function luminance(c) {
      function linear(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
      return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }
    function test_statusContrastAcrossThemes() {
      var backgrounds = ["#1e1e2e", "#eff1f5", "#777777"]
      var statuses = ["unchanged", "launched", "moved", "extra", "skipped", "failed"]
      for (var i = 0; i < backgrounds.length; i++) {
        reportView.canvasColor = backgrounds[i]
        for (var j = 0; j < statuses.length; j++) {
          var ink = reportView.outcomeColor(statuses[j])
          var fill = reportView.badgeFill(ink)
          var x = luminance(ink), y = luminance(fill)
          verify((Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05) >= 4.5,
            statuses[j] + " text must meet 4.5:1 on " + backgrounds[i])
        }
      }
    }
    function test_summaryHasColouredCounts() {
      reportView.report = Model.parse(JSON.stringify({ schema_version: 1, operation: 'reconcile', session: 'work', dry_run: true,
        report: { matched: 1, unchanged: 1, moved: 0, launched: 1, extras: 0, skipped: 0, failed: 0,
          windows: [
            { workspace: 1, workspace_name: null, class: 'terminal', title: 'Notes', status: 'unchanged', match_kind: null, message: null },
            { workspace: 2, workspace_name: null, class: 'browser', title: 'X', status: 'launched', match_kind: null, message: null }
          ] }, recovery: null }), 0, '', '')
      verify(waitForPolish(reportView))
      var summary = findChild(reportView, "reportSummary")
      compare(summary.count, 2)
      compare(summary.itemAt(0).label, "1 Would keep existing")
      compare(summary.itemAt(1).label, "1 Would restore")
      verify(summary.itemAt(0).ink !== summary.itemAt(1).ink)
    }
  }
  SignalSpy { id: closeSpy; target: reportView; signalName: "closeRequested" }
}
