import QtQuick
import Quickshell
import qs.Commons
import "RestoreReport.js" as Report

ShellRoot {
  QtObject {
    id: fakeBar
    property string position: "top"
    property string fontFamily: Style.font.family
    property var activePopout: null
    property int requested: 0
    property int released: 0
    function requestPopout(owner) {
      requested++
      if (activePopout && activePopout !== owner) activePopout.close()
      activePopout = owner
    }
    function releasePopout(owner) {
      released++
      if (activePopout === owner) activePopout = null
    }
  }
  FloatingWindow {
    id: anchorWindow
    visible: true
    implicitWidth: 800
    implicitHeight: 32
    Item { id: anchor; width: 24; height: 24 }
  }
  RestoreReportPopup {
    id: reportPopup
    anchorItem: anchor
    bar: fakeBar
  }
  FloatingWindow {
    id: captureWindow
    visible: true
    implicitWidth: 410
    implicitHeight: 500
    color: "transparent"
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      try {
        reportPopup.present(Report.parse(JSON.stringify({ schema_version: 1, operation: "reconcile", session: "Research — synthetic", dry_run: false,
          report: { matched: 1, unchanged: 1, moved: 0, launched: 1, extras: 0, skipped: 0, failed: 1,
            windows: [
              { workspace: 1, workspace_name: null, class: "terminal", title: "Project notes", status: "unchanged", match_kind: null, message: null },
              { workspace: 2, workspace_name: "Research", class: "browser", title: "Unicode λ · café", status: "launched", match_kind: null, message: null },
              { workspace: 2, workspace_name: "Research", class: "editor", title: "<b>Literal title</b>", status: "failed", match_kind: null, message: "Application did not appear before the deadline." }
            ] }, recovery: null }), 1, "Synthetic result. No helper was executed.", "Research"))
        if (fakeBar.requested !== 1 || fakeBar.activePopout !== reportPopup)
          throw new Error("Inherited onOpenChanged did not register exactly one coordinator owner")
        if (reportPopup.testGrabActive !== false) throw new Error("Focus grab active")
        verifyTimer.start()
      } catch (error) {
        console.error("REAL_POPUP_FAIL: " + error)
        Qt.quit()
      }
    }
  }
  Timer {
    id: verifyTimer
    interval: 300
    onTriggered: {
      try {
        var view = reportPopup.contentItem[0]
        if (view.width <= 0 || view.height <= 0) throw new Error("Report layout has no extent")
        fakeBar.activePopout.close()
        if (reportPopup.open || fakeBar.activePopout !== null || fakeBar.released !== 1)
          throw new Error("Coordinator close did not dismiss and release the report")
        reportPopup.reopen()
        if (!reportPopup.open || fakeBar.requested !== 2 || reportPopup.testGrabActive !== false)
          throw new Error("Reopen failed or activated a grab")
        console.log("REAL_POPUP_PASS: inherited coordinator handlers, close, reopen, no grab")
        view.maxListHeight = Style.space(400)
        captureWindow.implicitHeight = Math.ceil(view.implicitHeight + reportPopup.verticalContentInset)
        captureTimer.card = view.parent.parent
        captureTimer.card.parent = captureWindow.contentItem
        captureTimer.start()
      } catch (error) {
        console.error("REAL_POPUP_FAIL: " + error)
        Qt.quit()
      }
    }
  }
  Timer {
    id: captureTimer
    property var card: null
    property int pass: 0
    interval: 200
    onTriggered: {
      var width = pass === 0 ? 410 : 320
      var output = Quickshell.env("DESKLOOM_REPORT_ARTIFACT_DIR") + "/native-report-" + width + ".png"
      if (card.height <= reportPopup.verticalContentInset + reportPopup.contentItem[0].headerHeight) {
        console.warn("NATIVE_CARD_CAPTURE_UNAVAILABLE: resized card has no body extent")
        Qt.quit()
        return
      }
      if (!card.grabToImage(function(result) {
        if (result.saveToFile(output)) console.log("NATIVE_CARD_CAPTURE: " + output)
        else console.warn("NATIVE_CARD_CAPTURE_UNAVAILABLE: " + width)
        if (captureTimer.pass === 0) {
          captureTimer.pass = 1
          captureWindow.implicitWidth = 320
          resizeCapture.start()
        } else {
          reportPopup.dismiss()
          Qt.quit()
        }
      })) {
        console.warn("NATIVE_CARD_CAPTURE_UNAVAILABLE: grab rejected")
        Qt.quit()
      }
    }
  }
  Timer {
    id: resizeCapture
    interval: 50
    onTriggered: {
      var view = reportPopup.contentItem[0]
      captureWindow.implicitHeight = Math.ceil(view.implicitHeight + reportPopup.verticalContentInset)
      captureTimer.restart()
    }
  }
}
