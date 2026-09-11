// Shared by QML and Node. This module never launches a process or reads files.
var labels = { unchanged: "Found existing", moved: "Adjusted existing", launched: "Restored",
  extra: "Left alone", skipped: "Skipped", failed: "Failed" }
var plannedLabels = { unchanged: "Would keep existing", moved: "Would adjust existing",
  launched: "Would restore", extra: "Would leave alone", skipped: "Skipped", failed: "Failed" }

function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }
function integer(value) { return typeof value === "number" && isFinite(value) && Math.floor(value) === value && Math.abs(value) <= 9007199254740991 }
function nullableString(value) { return value === null || typeof value === "string" }

function valid(payload) {
  if (!object(payload) || payload.schema_version !== 1
      || (payload.operation !== "reconcile" && payload.operation !== "replace")
      || typeof payload.session !== "string" || typeof payload.dry_run !== "boolean"
      || (payload.recovery !== null && payload.recovery !== "succeeded" && payload.recovery !== "failed")
      || !object(payload.report)) return false
  var report = payload.report
  var counters = ["matched", "unchanged", "moved", "launched", "extras", "skipped", "failed"]
  for (var i = 0; i < counters.length; i++)
    if (!integer(report[counters[i]]) || report[counters[i]] < 0) return false
  // The engine permits at most 512 targets plus 512 extra windows.
  if (!Array.isArray(report.windows) || report.windows.length > 1024) return false
  var observed = { unchanged: 0, moved: 0, launched: 0, extras: 0, skipped: 0, failed: 0 }
  for (var j = 0; j < report.windows.length; j++) {
    var row = report.windows[j]
    if (!object(row) || !integer(row.workspace) || !nullableString(row.workspace_name)
        || typeof row.class !== "string" || typeof row.title !== "string"
        || typeof row.status !== "string" || !Object.prototype.hasOwnProperty.call(labels, row.status)
        || !nullableString(row.match_kind) || !nullableString(row.message)) return false
    observed[row.status === "extra" ? "extras" : row.status]++
  }
  for (var key in observed) if (report[key] !== observed[key]) return false
  var existing = report.unchanged + report.moved
  if (report.matched < existing || report.matched > existing + report.failed) return false
  return true
}

function unavailable(fallbackMessage, sessionName) {
  var diagnostic = String(fallbackMessage || "")
  return { available: false, complete: false, hasIssues: true, counts: null, dryRun: false, recovery: null,
    operation: "", session: String(sessionName || ""), title: "Report unavailable",
    diagnostic: diagnostic, summaryText: "Report unavailable" + (diagnostic ? ": " + diagnostic : ""),
    summary: "The helper did not return a supported restore report.",
    detail: String(fallbackMessage || "The restore outcome could not be verified."), groups: [] }
}

function parse(output, exitCode, fallbackMessage, sessionName) {
  var payload
  try { payload = JSON.parse(output) } catch (error) { return unavailable(fallbackMessage, sessionName) }
  if (!valid(payload)) return unavailable(fallbackMessage, sessionName)
  var report = payload.report
  var names = payload.dry_run ? plannedLabels : labels
  var groups = []
  var byWorkspace = Object.create(null)
  var incomplete = exitCode !== 0 || report.failed > 0 || report.skipped > 0 || payload.recovery !== null
  for (var i = 0; i < report.windows.length; i++) {
    var row = report.windows[i]
    var workspaceName = row.workspace_name === String(row.workspace) ? null : (row.workspace_name || null)
    var key = JSON.stringify([row.workspace, workspaceName])
    var group = byWorkspace[key]
    if (!group) {
      group = { workspace: row.workspace, workspaceName: workspaceName,
        label: "Workspace " + (workspaceName || row.workspace), windows: [] }
      byWorkspace[key] = group
      groups.push(group)
    }
    group.windows.push({ title: row.title || "(Untitled window)", className: row.class || "(Unknown application)",
      status: row.status, label: names[row.status], matchKind: row.match_kind, message: row.message || "" })
    if (row.status === "failed" || row.status === "skipped") incomplete = true
  }
  groups.sort(function(a, b) {
    if (a.workspace !== b.workspace) return a.workspace - b.workspace
    var x = a.workspaceName || "", y = b.workspaceName || ""
    return x < y ? -1 : x > y ? 1 : 0
  })
  var statuses = ["unchanged", "moved", "launched", "extra", "skipped", "failed"]
  var summary = []
  for (var k = 0; k < statuses.length; k++) {
    var status = statuses[k]
    var count = report[status === "extra" ? "extras" : status]
    if (count > 0) summary.push(count + " " + names[status])
  }
  var detail = []
  if (payload.dry_run) detail.push("No changes were executed; these are planned results.")
  if (payload.recovery === "failed") detail.push("Recovery failed. The desktop may be only partially restored.")
  if (payload.recovery === "succeeded") detail.push("Recovery succeeded; the requested restore did not complete.")
  if (exitCode !== 0) detail.push(String(fallbackMessage || "The helper exited unsuccessfully; results may be incomplete."))
  if (incomplete && detail.length === 0) detail.push("Some windows were skipped or failed. Review the details below.")
  var title = payload.dry_run ? (incomplete ? "Preview incomplete" : "Restore preview")
    : (incomplete ? "Restore incomplete" : "Restore complete")
  var summaryText = summary.join(" · ") || "No windows reported."
  return { available: true, complete: !incomplete, hasIssues: incomplete, dryRun: payload.dry_run, recovery: payload.recovery,
    counts: { matched: report.matched, unchanged: report.unchanged, moved: report.moved,
      launched: report.launched, extras: report.extras, skipped: report.skipped, failed: report.failed },
    operation: payload.operation, session: payload.session || String(sessionName || ""),
    title: title, summaryText: title + ": " + summaryText, diagnostic: String(fallbackMessage || ""),
    summary: summaryText, detail: detail.join(" "), groups: groups }
}

if (typeof module !== "undefined") module.exports = { parse: parse }
