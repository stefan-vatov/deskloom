# Cargo installation instead of AUR

The user wants the reference plugin's short install/configure/update/remove
README structure and direct compilation of their Hyprloom repo, without AUR.
The installed Omarchy add/update commands clone, validate, and enable plugins;
they do not parse README instructions or run installation hooks. The existing
explicit first-run button is the supported dependency-install boundary.

Use Cargo's locked, revision-pinned Git installation into a temporary root,
validate the built helper, then publish it into Deskloom's existing owned path
with the source/digest marker. An explicitly selected clean local checkout can
be used before publication. Never build in or clean the developer's target
directory. Missing prerequisites and failed builds leave the old helper alone.
Keep the terminal visible; do not install packages or invoke sudo automatically.

Evidence: installed omarchy-plugin-add and omarchy-plugin-update; the reference
README at https://github.com/egoist/omarchy-memory-usage; Cargo install docs at
https://doc.rust-lang.org/cargo/commands/cargo-install.html. The helper origin is
stefan-vatov/hyprloom, but its remote main is behind the tested local commit.
The user supplied stefan-vatov/deskloom as the plugin remote. Neither publication nor a live
plugin/helper replacement is part of this task.

Success means an explicit build from the pinned source, no AUR/package-manager
calls, repeat installation doing no work, and failures preserving prior files.
A source mismatch, missing locked revision, reused stale build, or prior-helper
mutation on build failure would invalidate the approach. Validate with isolated
installer fixtures and a real Cargo build, then full native panel checks.
The user's request authorizes these implementation changes, not publishing,
desktop restore, or modification of their installed helper.

## Constitutional check

Options: retain AUR; Cargo after an explicit click; install automatically when
the plugin loads. The requested Cargo path best supports "Workspace power
should remain approachable" while retaining the lean "Stability over release
speed or feature breadth". The exact package mechanism is constitutional
silence; it is an engineering choice, not a constitutional requirement.

Six effects inspected: reference/source research; README/developer guidance;
helper build/publication implementation; first-run UI and release metadata;
isolated tests and their network/build artifacts; configuring the supplied Git
remote. All are available and completed-lawful. No window operations or live
installation were needed. "Never move engine logic into Deskloom" is respected:
the plugin launches the compiler/helper and contains no new workspace logic.
"The user owns the live session" is respected by keeping test storage and the
compositor substitute isolated. The constitution was not modified.

## Outcome

The old installer failed five of six initial cases; the replacement passed all
ten fast installer cases. The real Cargo integration built the pinned source,
verified its genuine digest marker, repeated without rebuilding, then passed
all five native panel checks, including list/save/restore against the compiled
helper. Fourteen panel/packaging/CLI checks, eight report-model checks, twenty
Qt checks, plugin validation, protocol synchronization, shell syntax and local
documentation links also passed.

The first real-build attempt exposed DNS isolation in the test harness, not an
installer failure: hiding /run also hid the resolv.conf target. It was stopped,
the resolver file was mounted read-only into the test namespace, and the full
test passed on rerun. No installed desktop files were changed.

Publication remains intentionally outside scope. Deskloom's supplied remote is
configured but empty; Hyprloom's advertised remote main still predates the
pinned commit. The real build tested an isolated clone of that local commit,
not a download of a revision already available on GitHub. Publish Hyprloom
before the plugin that requires it.

Constitution gate: PASS (6 effects inspected, coverage: changed files and task
tool/process/network trace; unrelated repository wiring was not changed).

## Publication follow-up

The owner subsequently authorized committing every change, fixing all failing
checks, and pushing both main branches. Hyprloom was published first, making
the public Git installation path testable without a local source override.
An opt-in remote Cargo test now exercises that path with the same isolated
installation, digest, repeat-install, and full native panel assertions.

Hyprloom's first remote CI run exposed a synthetic test PID colliding with a
real runner process. The collision was reproduced locally in a read-only
namespace and fixed by injecting fixture process metadata; production safety
checks and every assertion remain unchanged. Deskloom now pins the published
test-fix revision `884dd246f060d0a9e94058b60070b00ccc8eb95c` in both the installer
and panel. The helper version and workspace behavior are unchanged.

Publication checks include Rust formatting, strict Clippy, all 274 Rust tests,
release compilation, both local-checkout and public-Git Cargo builds, native
panel/report checks, protocol synchronization, shell syntax, plugin validation,
and documentation links. Tests do not replace the live helper or plugin.

Hyprloom CI run 33287934379 passed at the pinned revision. The public-Git
installer and native panel checks also passed against that exact commit.
