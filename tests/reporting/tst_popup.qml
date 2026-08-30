import QtQuick
import QtTest
import "../.." as Deskloom

Item {
  id: harness
  width: 440
  height: 500
  QtObject { id: fakeBar }
  Deskloom.RestoreReportPopup {
    id: popup
    anchorItem: harness
    bar: fakeBar
    displayDuration: 100
  }
  TestCase {
    name: "RestoreReportPopup"
    when: windowShown
    function init() { popup.dismiss(); popup.containsMouse = false; popup.report = null }
    function sample() {
      return { available: true, complete: true, title: "Restore complete", session: "work",
        summary: "No windows reported.", detail: "", groups: [] }
    }
    function test_presentExpiresAndReopens() {
      popup.present(sample())
      compare(popup.open, true)
      compare(popup.triggerMode, "hover")
      tryCompare(popup, "open", false, 1000)
      verify(popup.report !== null)
      popup.reopen()
      compare(popup.open, true)
      popup.dismiss()
      compare(popup.open, false)
    }
    function test_hoverPausesAndRestarts() {
      popup.present(sample())
      popup.containsMouse = true
      wait(180)
      compare(popup.open, true)
      popup.containsMouse = false
      wait(35)
      compare(popup.open, true)
      tryCompare(popup, "open", false, 1000)
    }
    function test_emptyReopenDoesNotOpen() {
      popup.reopen()
      compare(popup.open, false)
    }
    function test_coordinatorCloseTargetsReport() {
      popup.present(sample())
      compare(popup.owner, popup)
      popup.owner.close()
      compare(popup.open, false)
      verify(popup.report !== null)
    }
  }
}
