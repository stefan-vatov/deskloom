---
status: normative
---
# Snapshot Operations

- Open reconciles the selected snapshot additively. It reuses or repairs
  matching windows, launches what is missing, and leaves unmatched windows
  alone.
- Replace is the destructive restore path. It must validate the selected
  snapshot and capture a safety autosnapshot before closing current windows,
  then restore through one guarded helper operation. It closes every current
  Hyprland client, including clients excluded by snapshot capture filters, and
  must attempt safety recovery if replacement fails.
- Deleting a saved snapshot requires a separate confirmation action before
  the delete operation runs.
- A failed or pending listing must not be presented as proof that snapshots
  are absent. Existing listed entries survive a refresh failure. Operation
  errors retain their complete plain-text explanation and remain readable
  through wrapping and scrolling rather than truncation.

## Restore feedback

Manual Open and Replace and an actual default-preset restore attempt consume
Hyprloom's opt-in structured report. Deskloom presents outcomes; it must not
infer window identity, recompute matching, or parse human diagnostic text to
decide which windows were found or restored.

Feedback groups named window outcomes by workspace and distinguishes existing,
adjusted, restored, extra, skipped, and failed windows. It is a passive temporary
popup: it must not grab desktop focus, it pauses dismissal while hovered, and
the last result can be reopened. Reports remain in memory, not persistent title
history. Another monitor's completed/busy login claim is not a restore result.

Outcome colors supplement explicit labels and agree between summary counts and
window rows. Status text remains readable against the popup theme; color alone
must not carry the distinction between existing and restored windows.

Read-only per-monitor diagnostics identify plugin/helper versions, snapshot-list
state and count, and retained outcome counts without exposing window titles or
executing helpers.

Unknown, absent, malformed, or unsupported reports and timeouts must be shown
as unavailable/incomplete, never success. A nonzero helper exit remains an
incomplete result even when the returned window outcomes all succeeded.
Replacement recovery is distinguished from successful restoration of the
requested preset. Dry-run output must be clearly labeled as planned work.
