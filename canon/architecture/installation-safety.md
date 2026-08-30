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
- Changed runtime code must acquire a fresh component identity on local
  installation, including its local imports, so a long-running shell cannot
  silently reuse an earlier cached implementation. Registry reload logs alone
  are not proof of the loaded version. Validation must compile the complete
  panel and exercise its process-to-report boundary, not only isolated views.
  Native validation must retain production command construction and readiness
  checks; isolate the executable and storage outside that boundary instead of
  replacing the method under test. Include list/save as well as restore paths.
