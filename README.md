# Deskloom

Deskloom is a small Omarchy bar widget for named Hyprland workspace snapshots.
It wraps [`hyprloom`](https://github.com/thethracian/hyprloom) and provides:

- named snapshot capture with overwrite support;
- restore without disturbing the current desktop;
- smart reconciliation that reuses, repairs, and launches only what is missing;
- a guarded **Replace** action that closes current windows before restoring;
- a preflight check before **Replace**, so an unreadable snapshot or missing
  app binary cannot close the current desktop;
- snapshot listing, refresh, and deletion;
- settings for starting with Omarchy and choosing a default snapshot;
- automatic default-snapshot restore a few seconds after Omarchy starts;
- a one-click AUR install action when `hyprloom` is missing. The installer opens
  in an Omarchy floating terminal so sudo can prompt normally.

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
close the current windows first. On multi-monitor setups, the startup action is
locked so it runs once for the desktop rather than once per bar instance.

Startup restore lives in the bar widget itself, so enabling Deskloom through the
normal Omarchy marketplace also enables the default-preset behavior.

## Dependency behavior

Omarchy's plugin clone/install command intentionally does not execute plugin
code or install hooks, so a plugin cannot safely force a package install merely
because it was cloned from a website. Deskloom detects `hyprloom` and exposes a
first-run install button. That button opens Omarchy's visible package installer:

```bash
omarchy-launch-floating-terminal-with-presentation omarchy-pkg-aur-add hyprloom
```

The AUR helper uses an idempotent `yay --needed` install. The user sees the
normal terminal output and can enter their sudo password there; Deskloom never
collects or handles the password itself.
