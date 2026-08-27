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
