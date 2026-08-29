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
