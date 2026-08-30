# Restore reporting tests

Run from the repository root with `bash tests/reporting/run.sh`.
The runner uses Node and `/usr/lib/qt6/bin/qmltestrunner`, without a display
connection. It never instantiates Panel.qml, Quickshell, or any helper process.
The QML tests inject deterministic qs.Commons theme tokens and test doubles for
qs.Ui.Button and PopupCard. The popup double exposes hover state for lifecycle
tests; compositor focus and installed theme appearance require separate review.

The capture test writes `tests/reporting/restore-report.png` using synthetic
data. This is a Qt item render, not a screenshot of the live desktop.

Run `node tests/reporting/real-popup.cjs` for the additional native Quickshell
check. It copies the installed Commons/Ui assets into a temporary /tmp fixture,
uses an isolated runtime directory and offscreen platform, and loads only
RestoreReportPopup with synthetic data. Original files remain read-only.
It instruments only a read-only probe of the real HyprlandFocusGrab.active
property. It checks inherited coordinator registration/release, close/reopen,
positive view dimensions, and an inactive grab. Actual Style may run its
read-only font/Hyprland probes; the isolated runtime and removed compositor
environment keep these away from the active desktop.

The native offscreen platform warns that window masks are unsupported. Direct
PopupWindow capture returned an unsaveable image. After the lifecycle checks,
the harness reparents the same real BorderSurface/card to an offscreen
FloatingWindow and captures it at 410 and 320 px with the production scroll
cap. The successful real-theme card render is `native-report-410.png`.
The 320 px resize lost body extent on the offscreen platform, so no valid
narrow capture is retained. These are not compositor screenshots. Native focus
delivery is not tested; the real grab's active binding is tested. Generated
source and runtime directories are removed after the native run.

## TDD record

- Tracer red: Node failed with RestoreReport.js missing; Qt failed with
  RestoreReportView.qml missing.
- Tracer green: one parser assertion case and one rendered plain-text row
  passed (Node 1 test, Qt 3 including setup/cleanup).
- Model expansion red: malformed data, statuses/grouping, recovery, preview,
  and list limits failed (5 failures). Green: all 6 Node tests passed.
- UI expansion red: popup missing, close signal/button and detail absent
  (3 Qt failures). Green: 10 Qt checks passed including hover and expiry.
- Long-diagnostic regression red: diagnostic stayed outside the scroll area.
  Green: moved all report details into bounded scrolling content while keeping
  the close button visible (13 Qt checks passed).
- Long-title red: unbounded title layout; green: title and class/status
  elide after two lines, while diagnostic text remains scrollable.
- Numeric grouping red: null and numeric workspace names formed separate
  groups; green: default numeric names coalesce while named groups remain.
- Native compile red: PopupCard rejected Timer in its visual content list.
  Green: the expiry Timer is now an explicit object property.
- Counter consistency red: an unchanged count with no rows was accepted.
  Green: all six disjoint counters equal their row counts, with
  unchanged + moved <= matched <= unchanged + moved + failed. Synthetic
  fixtures now satisfy the same constraints.

## Integration interface

`RestoreReport.parse(output, exitCode, fallbackMessage, sessionName)` accepts
the complete JSON stdout string and returns a presentation model:

- `available`, `hasIssues`, `complete`: report validity and outcome flags.
- `counts`: the seven validated counters, or null when unavailable.
- `summaryText`: title plus compact result summary, suitable for Panel status.
- `diagnostic`: the original fallback message, preserved without trimming.
- `title`, `session`, `summary`, `detail`, `groups`: view content.
- `operation`, `dryRun`, `recovery`: validated envelope metadata.

Each group has `workspace`, `workspaceName`, `label`, and `windows`.
Each window has `title`, `className`, `status`, `label`, `matchKind`, `message`.
Strings are plain text, not HTML-escaped; the view uses Text.PlainText.

RestoreReportPopup requires inherited `anchorItem` and `bar` properties.
Its `report` starts null. `present(model)` stores and shows a report;
`reopen()` shows the retained report; `dismiss()` closes without clearing it.
`close()` delegates to dismiss for the bar coordinator. The popup owns its
coordinator entry and uses `triggerMode: "hover"` to disable the focus grab.
`displayDuration` defaults to 12000 ms. Hover pauses expiry; leaving restarts
the full duration. Main closes its own panel before calling present/reopen.
