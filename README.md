# Deskloom

Deskloom is a small Omarchy bar widget for named Hyprland workspace snapshots.
It wraps [`hyprloom`](https://github.com/thethracian/hyprloom) and provides:

- named snapshot capture with overwrite support;
- restore without disturbing the current desktop;
- smart reconciliation that reuses, repairs, and launches only what is missing;
- a guarded **Replace** action that validates the target, saves a safety
  autosnapshot, closes current windows, restores in one helper operation, and
  attempts safety recovery if the replacement fails;
- snapshot listing, refresh, and deletion;
- a temporary restore report showing what was found, adjusted, restored,
  skipped, or failed, grouped by workspace;
- settings for starting with Omarchy and choosing a default snapshot;
- automatic default-snapshot restore a few seconds after Omarchy starts;
- a one-click helper install action when `hyprloom` is missing. The installer
  opens in an Omarchy floating terminal so sudo can prompt normally.

## Development install

From this checkout:

```bash
./install-local.sh
```

The plugin runs as unsandboxed QML inside `omarchy-shell`, like other Omarchy
shell plugins. The local installer validates a complete staged copy before
swapping it into the live plugin directory, so removed files do not linger
after upgrades. Review changes before enabling it.

The local installer gives each distinct QML/JavaScript bundle a content-specific
entry-point URL. This prevents a long-running shell from silently reusing a
cached older plugin after an update; it does not require a desktop restart.

## Restore feedback

After Open, Replace, or a login restore, Deskloom shows a small report near its
bar button. Each workspace lists its windows by title and application, with
labels for **Found existing**, **Adjusted existing**, **Restored**, **Left
alone**, **Skipped**, and **Failed**. Failures include the helper's explanation;
recovery is shown separately from completion of the requested preset.

Matching count and row badges make outcomes scannable: blue for found existing,
green for restored, amber for adjusted, gray for left alone, purple for skipped,
and red for failed. Badge contrast adapts to the popup background; labels remain
explicit so color is never the only way to tell outcomes apart.

The report does not take focus. It closes after 12 seconds unless hovered; move
the pointer away to restart the timer, or choose Close. Use **Last restore** in
the main panel to reopen it. Only the most recent result is held in memory, and
large reports scroll. Missing or unsupported output is reported as unavailable,
not as a successful restore.

Snapshot-operation errors are wrapped, selectable plain text. Longer errors
scroll so the explanation and usage details remain readable. A failed list
request is shown as a loading failure, not an empty collection of snapshots.

This requires the matching Hyprloom build with `--report-json` support; install
the plugin and helper together. Snapshot matching and restoration remain in
the [Hyprloom CLI](https://github.com/stefan-vatov/hyprloom).

## Settings

Open the bar panel and choose **Settings** to:

- enable **Start on login**;
- select one saved snapshot as the **Default preset**;
- refresh the snapshot list manually when needed.

When both settings are enabled, Deskloom reconciles the selected preset shortly
after the Omarchy shell starts. The reconciliation is additive and leaves
unmatched windows alone; use the snapshot's **Replace** action when you want to
close the current windows first. Replace stores a safety autosnapshot before
closing anything, so a failed restore leaves a recoverable copy. On
multi-monitor setups, the startup action is locked so it runs once for the
desktop rather than once per bar instance.

Replace intentionally closes every Hyprland client currently open, including
windows excluded by the capture filters. Use Open when extra or ignored
windows should remain untouched.

Startup restore lives in the bar widget itself, so enabling Deskloom through the
normal Omarchy marketplace also enables the default-preset behavior.

## Dependency behavior

Omarchy's plugin clone/install command intentionally does not execute plugin
code or install hooks, so a plugin cannot safely force a package install merely
because it was cloned from a website. Deskloom detects `hyprloom` and exposes a
first-run install button. That button opens an Omarchy floating terminal and
runs the idempotent helper installer. It first tries the AUR package:

```bash
omarchy-launch-floating-terminal-with-presentation omarchy-pkg-aur-add hyprloom
```

The AUR helper uses an idempotent `yay --needed` install. If the package has not
been published yet, the installer uses the local `~/code/hyprloom` checkout or,
after the fork's tagged source is published, clones that tag and builds it in
the user's home directory. The user sees the normal terminal output and can
enter their sudo password there; Deskloom never collects or handles the
password itself.

The installer accepts only `hyprloom 0.4.0-dev.2` and the pinned source revision, so an
older binary or stale checkout cannot silently satisfy the dependency check.

`0.4.0-dev.2` is a local development build, not a published release. A local
installation retains a clean source snapshot and points its helper installer
at that snapshot; the remote tag fallback is available only after publication.

The helper's local integration check can be run from this checkout with:

```bash
./tests/install_helper_integration.sh
```

Reporting checks:

```sh
node --test tests/panel_reporting.test.mjs tests/install_reporting.test.mjs
./tests/reporting/run.sh
HYPRLOOM_BIN=/path/to/hyprloom node --test tests/cli_report_contract.test.mjs
node tests/native-panel/run.cjs
```

The cross-layer test uses a real CLI build with isolated snapshots and a fake
compositor executable; it never restores the live desktop.

The native-panel check requires Bubblewrap and compiles the complete production
panel with its actual command builder and process/output handlers. A fake
helper is mounted only inside a private, offscreen filesystem sandbox.
It also reproduces the unchanged-URL cache behavior that made reload logs alone
insufficient evidence of a successful update.

With the pinned helper installed, run
`DESKLOOM_TEST_INSTALLED_HELPER=1 node tests/native-panel/run.cjs` to also test
native list/save/restore using the real CLI, temporary snapshots, and a fake
read-only compositor. No real desktop restore is performed.

To inspect a loaded monitor instance without restoring anything:

```sh
omarchy-shell thethracian.deskloom.DP-1 status
```

Use your monitor name in place of `DP-1` (URL-encoded if necessary). The result
includes the loaded component URL, separate plugin/helper versions, helper
readiness, snapshot-list state/count, and retained report counts. It does not
expose window titles or start helper operations.
