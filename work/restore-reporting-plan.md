# Restore reporting feature

## Scope and tracer bullet

Add an optional structured report to Hyprloom and a lightweight, transient
Deskloom presentation. Matching, launching, safety, and recovery stay in Rust.
Start with a failing real-CLI test for one already-open window and a failing
QML/model test showing that window; connect this vertical slice before widening.

## CLI contract

`restore NAME --reconcile --report-json` and `replace NAME --report-json`
emit one JSON report on stdout after an operation produces a report. Version 1
contains `schema_version`, `operation`, `session`, `dry_run`, `report`, and
`recovery` (null, succeeded, or failed). The report includes the existing seven
counters and per-window workspace ID/name, app class/title, status, optional
match kind, and optional diagnostic. Human diagnostics go to stderr in report
mode; default text output and exit semantics remain unchanged. Fatal/early
errors without a report leave stdout empty and explain the error on stderr.
Partial results still exit nonzero. Dry-run outcomes are plans, not actions.
Replacement reports describe the target attempt; recovery is reported separately
and never turns the failed target attempt into success.

## UI direction and behavior

Operate mode: extend the existing Omarchy popup language, theme, typography,
and spacing. No new identity, extra window-management policy, or log parser.
Show preset name, brief counts, then workspace headings with window titles,
app fallback names, and clear status labels: Found existing, Adjusted existing,
Restored, Left alone, Skipped, Failed. Render data as plain text, with a bounded
scrolling list and explanatory errors. A passive popup opens after manual Open,
Replace, and an actual login-restore attempt. Dismiss after 12 seconds, pause
while hovered, allow explicit close, and expose Last restore to reopen it.
Keep only the last report in memory, not a durable history of window titles.

Malformed/missing/unsupported JSON, nonzero exits, timeouts, and recovery must
never be rendered as successful restores. No popup for list/save/delete or a
login restore skipped because another monitor/session already claimed it.

## TDD sequence

1. Red/green: one existing target -> real CLI JSON -> model -> popup row.
2. Engine outcomes: unchanged, moved, launched, skipped, failed, extras;
   quiet/verbose parity and dry-run plans; preserve duplicate-terminal fix.
3. CLI boundary: opt-in/default compatibility, missing session, stdout purity,
   partial failures and exit codes, replacement reporting/recovery safety.
4. Presentation: numeric/named workspaces, Unicode/empty titles, malformed data,
   failure messaging, large reports, timer/hover/dismiss/reopen behavior.
5. Panel wiring and packaging: manual/boot/replace paths request JSON; all new
   assets are installed transactionally. A real CLI report is consumed by the
   real presentation parser without parsing English diagnostic lines.
6. Full Rust gates, headless QML/model tests, installer checks, synthetic visual
   inspection; update the smallest Canon pages and user-facing changelogs.

## Deployment and safety

Install matching local builds with exact source/digest pins and backups, using
the prior local-build workflow. Keep unfinished governance changes untouched.
Hold the existing boot lock during plugin reload so installation does not
restore the live desktop. Validate reporting with fixtures and a read-only
preview; do not execute a real restore or close windows to prove the UI.

## Decision and evidence

User explicitly requested the feature in both layers, TDD, a tracer bullet,
and a plan followed by implementation. Existing free-form details are gated
by verbosity and insufficient as a machine contract. Tests that fail to
distinguish existing/restored/failed windows, polluted JSON output, focus grabs,
or live mutations during reporting would invalidate the implementation.
Review at completion against these acceptance cases, not only screenshots.

## Completion audit

The tracer began with failing real-CLI and QML/model cases, then passed as one
vertical slice before status, failure, lifecycle, and packaging expansion.
The final gates passed: 269 Rust tests, strict Clippy, formatting, 18 JavaScript
tests, 17 Qt checks, helper installation, plugin validation, and both protocol
sync checks. Native Omarchy components compiled with an inactive focus grab;
an independent finish review found no material issues. See
`tests/reporting/README.md` for the detailed red/green presentation record.

Installed matching local `0.4.0-dev.1` builds with authentic source/digest pins
and a retained rollback copy. The installed helper's read-only preview passed
through the installed parser. Preset bytes, shell settings, window identities,
and window layout were unchanged. No real restore or replacement was executed.
Live compositor focus delivery and native narrow-screen rendering remain
unverified; synthetic tests do not establish those properties.

Installation provenance and backups:
`/home/thethracian/.local/share/deskloom/local-builds/20260830.reporting.Fpa6Rd/INSTALLATION.md`.

## Follow-up: missing live reports (2026-08-30)

The user saw neither the automatic report nor Last restore. Installed version
and report assets were present, but that did not establish the loaded runtime.
A native test reproduced duplicate `onOpenedChanged` handlers in the complete
Panel, which prevented fresh compilation. An isolated QML-engine experiment
also proved unchanged component URLs reused old code after a rescan; the
shell's guarded `Qt.clearComponentCache` call is unavailable in this runtime.
The earlier isolated-view checks could not catch either integration failure.

Merge the open-state handlers and install local runtime assets beneath their
content hash, including imported QML/JavaScript. Verify the entire production
Panel and real Process/StdioCollector boundary with a fake helper. Add read-only
per-monitor IPC exposing loaded component identity and report counts, not
window titles or restore commands. This distinguishes deployed files from
running code and retained results without mutating the desktop.

The saved X web app also reproduced a separate CLI identity issue: its old
address excluded a reopened window even with the same generated site/profile
class. Reuse only a unique matching web app, preserving rejection of reused
addresses, other sites/profiles, and generic Chromium identities. Tests cover
ambiguity initially, after planning, and immediately before placement. Refuse
the last case rather than moving a newly ambiguous window; exact saved window
identities and positively correlated launches retain their existing behavior.

Both fixes preserve saved snapshot format and require no resaving. The local
follow-up build is `0.4.0-dev.2`. It is now installed, and all three monitor
instances report its new content-specific URL and helper readiness through IPC.
274 Rust tests, 19 JavaScript tests, 17 Qt checks, and three native checks passed.
The installed parser accepted the old preset preview with no planned launches;
workspace 8 X is existing. Window identities/layout, preset bytes, and shell
settings remained unchanged. No live restore was triggered for verification.

Deployment evidence and rollback:
`/home/thethracian/.local/share/deskloom/local-builds/20260830.reporting-fix.sC64Sh/INSTALLATION.md`.
