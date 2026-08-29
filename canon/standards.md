---
status: normative
validation: [.github/workflows/harder-to-fool.yml]
---
# Standards

Deskloom must never collect or handle the user's sudo password. A dependency
installation that may prompt for sudo must run in a visible Omarchy floating
terminal so the normal package tooling prompts the user directly.

The vendored Harder to Fool `CODE.md` and the inlined `AGENTS.md` protocol
block must remain synchronized and pass the repository's Harder to Fool sync
check.
