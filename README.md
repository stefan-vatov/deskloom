# Deskloom for Omarchy

Save your Hyprland workspace layouts and open them again from the Omarchy bar.
Deskloom is the lightweight UI for [Hyprloom](https://github.com/stefan-vatov/hyprloom),
the Rust CLI that captures, matches, and restores your windows.

## Features

- Save named workspace snapshots and overwrite them when your layout changes.
- **Open** reuses existing windows, adjusts their layout, and launches what is
  missing. Unmatched windows stay where they are.
- **Replace** asks for confirmation before closing current windows. It validates
  the preset and saves a safety snapshot first, then attempts recovery if needed.
- See color-coded restore results grouped by workspace, and reopen **Last restore**.
- Choose a default preset to open when Omarchy starts.
- Build the matching Hyprloom helper from source in a visible terminal—no AUR package.

## Install

Requires Omarchy with shell-plugin support, Hyprland, Git, Rust/Cargo, and a C
toolchain. Check your build tools with:

```bash
command -v git cargo rustc cc
```

If tools are missing, install them first. On Omarchy, `omarchy pkg add git rust base-devel`
provides them from Arch packages. If you already use Rust through rustup, keep
that toolchain instead of also installing the `rust` package.

Add and enable the plugin:

```bash
omarchy plugin add https://github.com/stefan-vatov/deskloom.git --enable
```

Open Deskloom in the bar and choose **Build and install Hyprloom**. A floating
terminal downloads the pinned source and Cargo dependencies, then compiles and
installs the helper. The first build can take several minutes. When it finishes,
the panel shows your saved snapshots and the save controls.

Omarchy does not execute README instructions or install hooks. Installing the
plugin and choosing to build its helper are separate, explicit actions.

This is a development build. To work on unpublished changes, use the
[local development workflow](docs/development.md).

The widget defaults to the right section. To move it:

```bash
omarchy bar move thethracian.deskloom --section right
```

## Configure

Open the panel, save a snapshot, then choose **Settings** to select its
**Default preset** and enable **Start on login**. Startup restore uses Open's
additive behavior and runs once for the desktop, including multi-monitor setups.

Use **Open** when unrelated windows should remain untouched. **Replace** closes
every current Hyprland window, including windows excluded by capture filters;
save your work before confirming it. Deleting a saved snapshot has its own
confirmation.

## Restore reports

After Open, Replace, or a login restore, a temporary popup shows each window's
title, application, workspace, and outcome:

- Blue: found existing. Green: restored. Amber: adjusted existing.
- Gray: left alone. Purple: skipped. Red: failed, with an explanation.

Labels remain explicit, so color is not the only distinction. The popup does
not take focus; hover to keep it open, or use **Last restore** to reopen it.
Only the latest report is kept in memory. Long reports and operation errors
scroll; missing reports are never presented as successful restores.

## Dependencies and security

Like other Omarchy plugins, Deskloom runs unsandboxed with your user permissions.
Review the code before enabling it. Window-management logic stays in Hyprloom.

The build button runs `cargo install` against an exact Git revision with
`--locked`, in a temporary build/install directory. After version and help checks,
it installs `~/.local/bin/hyprloom` with a source-revision and SHA-256 marker.
A matching verified install is reused. A failed build leaves the old helper
untouched. There are no AUR calls, automatic package installs, or sudo prompts.

The helper build needs network access to fetch source and dependencies; normal
snapshot operations use your local Hyprland session. A safety snapshot preserves
window-launch/layout information—it cannot guarantee recovery of unsaved app data.

## Update

```bash
omarchy plugin update thethracian.deskloom
```

If an update requires a different helper revision, the panel offers **Build and
install Hyprloom** again. Saved presets remain in place. Local development
installs are not Git-managed; update those with `./install-local.sh` from the checkout.

## Remove

```bash
omarchy plugin remove thethracian.deskloom
```

This removes the plugin, not your saved Hyprloom presets or the compiled helper.

## Development

See [local installation, tests, and diagnostics](docs/development.md).

## License

MIT (declared in the plugin manifest).
