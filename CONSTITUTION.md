# CONSTITUTION.md

## Preamble

Deskloom exists to make Hyprloom's workspace-management experience pleasant
for Omarchy users who use workspaces extensively. It replaces tedious window
management with a clear, approachable way to configure workspace arrangements,
switch between them, and boot directly into a chosen workspace. Its interface
should feel easy and unconfusing, following sound UI and UX principles.

## Founding Principles

1. **The user owns the live session.** Deskloom must never silently close
   windows or erase the user's current setup, even when doing so would make
   automation simpler. This rejects convenience bought with unchosen state
   loss.

2. **Destructive intent must be explicit.** Additive and destructive actions
   must remain clearly distinct. Replacing a session requires informed user
   confirmation. This rejects ambiguous interactions that conceal destructive
   consequences.

3. **Preservation is a first-class workflow.** Users must be able to load saved
   workspace layouts without being forced to discard unrelated windows or
   ongoing work. This rejects clean-slate assumptions as the only path to a
   useful layout.

4. **Complexity is a design problem.** Powerful features should be decomposed
   into small, understandable interactions. Deskloom should improve or expand
   its interface rather than expose raw complexity or remove useful capability
   merely to keep the interface small.

5. **Workspace power should remain approachable.** Any workspace-heavy
   Omarchy user should be able to configure, switch, and boot into layouts
   through a clear interface. This rejects an experience that assumes
   specialist knowledge of the underlying machinery.

## Growth Directives

- **Become the daily driver for advanced workspace management.** Deskloom
  should grow from a convenient plugin into the tool Omarchy users rely on
  throughout everyday work.
- **Expand capability without expanding the domain.** Future features may
  evolve with user needs, but each must directly serve Hyprland workspace
  management for Omarchy users.
- **Earn deeper trust as usage grows.** Every stage of growth should make
  Deskloom more intuitive, consistent, stable, and unsurprising. Bugs are
  incompatible with daily-driver quality.

## Boundaries

- **Never move engine logic into Deskloom.** Deskloom remains a lightweight UI
  wrapper around Hyprloom. Complex workspace behavior belongs in the Hyprloom
  CLI, not in the plugin.
- **Never take responsibility outside workspace management.** Deskloom must
  not configure, modify, or manage unrelated parts of the user's system.
- **Never become a general-purpose desktop integration.** Deskloom is
  intentionally specific to Omarchy and its chosen window manager. It may
  follow Omarchy if that window manager changes, but it must not broaden
  independently to unrelated distributions, compositors, or desktops.

## Tension Pairs

- **A clear experience over a minimal interface** — but never at the cost of
  moving complex workspace logic into Deskloom. Expand the UI where clarity
  requires it; add missing engine behavior to Hyprloom.
- **Stability over release speed or feature breadth** — but never at the cost
  of abandoning valuable workspace capabilities. Do the additional work needed
  to make a feature dependable before releasing it.
- **Safe defaults over frictionless repetition** — but never at the cost of
  denying deliberate user control. Destructive behavior is safe and explicit
  by default; users may consciously configure bypasses for repeated prompts.

## Amendments

This constitution was ratified on 2026-08-29. It carries no amendment log; Git
is the authoritative history of replaced constitutional text.

### Amendment Process

Only the human project owner may initiate, approve, and ratify an amendment.
Amendments are purely owner-initiated; there is no automatic or periodic review
trigger. The owner invokes the constitution-writing skill, and every affected
section goes through the same questioning, conflict-checking, and explicit
approval process used for creation.

An approved amendment replaces the old constitutional text. Agents may apply
this constitution but may never alter it or initiate amendments.
