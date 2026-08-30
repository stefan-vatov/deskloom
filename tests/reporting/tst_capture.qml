import QtQuick
import QtTest
import "../.." as Deskloom
import "../../RestoreReport.js" as Model

Rectangle {
  id: frame
  width: 460
  height: 720
  color: "#202020"
  Deskloom.RestoreReportView {
    id: view
    x: 20
    y: 20
    width: parent.width - 40
    maxListHeight: 640
    report: Model.parse(JSON.stringify({
      schema_version: 1, operation: "reconcile", session: "Research", dry_run: false, recovery: null,
      report: { matched: 2, unchanged: 1, moved: 1, launched: 1, extras: 1, skipped: 1, failed: 1,
        windows: [
          { workspace: 1, workspace_name: null, class: "terminal", title: "Project notes", status: "unchanged", match_kind: "exact", message: null },
          { workspace: 1, workspace_name: null, class: "editor", title: "RestoreReport.qml", status: "moved", match_kind: "class", message: null },
          { workspace: 2, workspace_name: "Research", class: "browser", title: "Unicode λ · café", status: "launched", match_kind: null, message: null },
          { workspace: 2, workspace_name: "Research", class: "terminal", title: "", status: "extra", match_kind: null, message: null },
          { workspace: 3, workspace_name: null, class: "editor", title: "Private window", status: "skipped", match_kind: null, message: "No safe launch command was available." },
          { workspace: 3, workspace_name: null, class: "browser", title: "<b>Literal title</b>", status: "failed", match_kind: null, message: "Application did not appear before the deadline." }
        ] }
    }), 1, "Some requested windows could not be restored.", "Research")
  }
  TestCase {
    name: "RestoreReportCapture"
    when: windowShown
    function test_syntheticScreenshot() {
      verify(waitForPolish(view))
      verify(view.height <= frame.height - 40)
      var path = decodeURIComponent(Qt.resolvedUrl("restore-report.png").toString().replace(/^file:\/\//, ""))
      grabImage(frame).save(path)
    }
  }
}
