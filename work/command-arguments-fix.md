# Command-argument regression: 2026-08-30

Objective: restore listing/saving and readable diagnostics without changing
the user's saved preset or live windows. The user reported an empty list and
an unrecognized `[object ...]` command after the previous installation.

Evidence: the real installed CLI lists cozy-default with 14 windows, and its
SHA-256 remains 3f5e85035fb1aba11db3e1de33f42fde2ed12c8db3e8085f144541ef9c05c951.
The helper version/pin also matches. These reject deletion and wrong-helper
hypotheses. A new native test of the production command builder fails with
`list: expected ["list"], got ["[object Arguments]"]`. Renaming its `arguments`
parameter to `args` makes it pass. A subsequent full-panel test fails on lost
error lines, then passes after preserving stderr and adding a scrollable view.

The previous test substituted command construction, so passing it did not
establish that the installed UI could call the helper. The new tests keep
production methods intact, using a private Bubblewrap namespace to substitute
only the executable/marker. An additional run uses the actual installed CLI
with temporary storage and a fake read-only compositor; it verifies listing,
persisted saving, and an existing-window report. Native QML, real process pipes,
and actual CLI parsing are now covered together. A recurrence of bad argv or
an unexpected compositor dispatch would invalidate the fix.

Authority is the user's ongoing repair request. Prefer a plugin-only update;
leave the correct CLI and all snapshots untouched. Back up the installed
plugin/settings, hold the boot-restore lock across reload, verify actual loaded
component identity plus snapshot count on every monitor, and inspect the live
panel. Stop on any unexpected snapshot/window change. No live save or restore
is needed to prove this repair. Canon now requires command-boundary validation
and readable diagnostics rather than treating list failure as missing data.

Validation before deployment: five native checks including the real CLI run,
21 JavaScript tests, 17 Qt checks, protocol sync, and whitespace checks passed.

Deployed plugin-only 0.4.0-dev.3. Live IPC on all three monitors now reports
one successfully loaded snapshot; the visible panel shows cozy-default with
14 windows. The CLI, source pin, preset and settings were left unchanged.
The UI inspection also exposed a misleading exhausted-lock notice; a red/green
regression now requires "skipped" rather than claiming a restore is running.
Deployment and rollback evidence:
`/home/thethracian/.local/share/deskloom/local-builds/20260830.command-fix.Mkh4YX/INSTALLATION.md`.
