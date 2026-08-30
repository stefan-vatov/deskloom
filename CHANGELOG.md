# Changelog

## Unreleased

### Added

- Added temporary, workspace-grouped restore reports after Open, Replace, and
  login restore, showing which windows already existed and which were restored.
- Added hover-paused dismissal and Last restore to reopen the most recent result.
- Added explicit skipped, failed, unavailable, timeout, and recovery feedback.

### Compatibility

- Requires the matching Hyprloom build with `--report-json`; update the helper
  and plugin together. Saved presets and existing settings are unchanged.
- This work is a local development build, not a published release.

## 0.4.0-dev.4 (local) - 2026-08-30

### Changed

- Added color-coded counts and window labels so existing and newly restored
  windows are easier to distinguish at a glance.
- Kept explicit outcome labels and adapted badge contrast to the popup theme.

### Compatibility

- Plugin-only presentation update; Hyprloom `0.4.0-dev.2`, saved snapshots,
  settings, and restore behavior are unchanged.

## 0.4.0-dev.3 (local) - 2026-08-30

### Fixed

- Fixed listing and saving failing with an unrecognized `[object Arguments]`
  command; existing snapshots had not been deleted.
- Kept complete operation errors in a wrapped, selectable, scrollable area.
- Distinguished failed or pending listings from a confirmed empty collection.
- Clarified that exhausting startup-lock retries skips automatic restore;
  it does not prove another restore is still running.

### Compatibility

- Plugin-only fix; the pinned Hyprloom `0.4.0-dev.2` and saved formats are unchanged.

## 0.4.0-dev.2 (local) - 2026-08-30

### Fixed

- Fixed fresh plugin loading failing because of duplicate open-state handlers.
- Fixed local updates leaving an older cached plugin running without reports.

### Added

- Added per-monitor read-only diagnostics for the loaded build and report state.
