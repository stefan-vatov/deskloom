---
status: normative
---
# Installation Safety

- A local plugin install must build and validate a complete staged copy before
  replacing the live plugin. Replacement must remove files absent from the new
  copy. If replacement or its post-install registration fails, the installer
  must restore the prior installation and its enabled state when one existed;
  a failed first install must not leave a partial live plugin.
- Deskloom accepts a helper only when the binary reports the expected release
  and its installed digest is tied to the pinned helper source revision. A
  source fallback must build from a clean checkout at that pinned revision.
