import QtQuick
import qs.Commons
import qs.Ui

PopupCard {
  id: root
  property var report: null
  property int displayDuration: 12000

  // Own the coordinator entry so switching closes this report, not Panel.
  owner: root
  triggerMode: "hover"
  contentWidth: fittedContentWidth(Style.space(410))
  contentHeight: fittedContentHeight(reportView.implicitHeight)

  function present(model) {
    if (!model)
      return;
    report = model;
    reopen();
  }
  function reopen() {
    if (!report)
      return;
    open = true;
    refreshTimer();
  }
  function dismiss() {
    expiry.stop();
    open = false;
  }
  function close() {
    dismiss();
  }
  function refreshTimer() {
    if (open && !containsMouse)
      expiry.restart();
    else
      expiry.stop();
  }
  onContainsMouseChanged: refreshTimer()
  onOpenChanged: refreshTimer()

  property Timer expiryTimer: Timer {
    id: expiry
    interval: root.displayDuration
    onTriggered: root.dismiss()
  }
  RestoreReportView {
    id: reportView
    width: parent.width
    report: root.report
    maxListHeight: root.availableCardHeight > 0 ? Math.max(0, Math.min(Style.space(400), root.availableCardHeight - root.verticalContentInset - headerHeight)) : Style.space(400)
    fontFamily: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
    onCloseRequested: root.dismiss()
  }
}
