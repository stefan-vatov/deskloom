# Local development

## Install from a checkout

Requires Omarchy's shell/plugin commands, Git, Cargo, rustc, and a C toolchain.
From the Deskloom checkout:

```bash
./install-helper.sh
./install-local.sh
```

The helper installer builds the pinned revision from
[stefan-vatov/hyprloom](https://github.com/stefan-vatov/hyprloom) using
`cargo install --git ... --rev ... --locked --bin hyprloom`. It does not follow
`main`, use an AUR package, or install a similarly named crates.io package.

If that revision is not published yet, explicitly select a clean Hyprloom
checkout at the pinned commit:

```bash
DESKLOOM_HYPRLOOM_SOURCE="$HOME/code/hyprloom" ./install-helper.sh
./install-local.sh
```

The override uses `cargo install --path` with the same lockfile and revision
checks. Wrong revisions and dirty checkouts are errors, not permission to build
something else. Both modes use fresh temporary build/install directories; they
do not run `cargo clean` or modify the source checkout's `target/` directory.
Version/help checks and the source/digest marker gate publication into
`~/.local/bin/`. The script is safe to repeat for an already verified helper.

The local plugin installer validates a complete staged copy before replacing
the live plugin, removes obsolete files, and rolls back on installation failure.
It gives each QML/JavaScript bundle a content-specific entry point to avoid
reusing cached components in a long-running shell. No desktop restart is needed.
It is not a Git clone, so use this script again rather than `omarchy plugin update`.

If Start on login is enabled, a plugin reload can trigger the configured preset.
Disable that setting before development reinstalls when you do not want a restore.

## Validate changes

The fast installer tests require Node.js and Bubblewrap. They run the real shell
installer with a fixture Cargo executable in a private, offline filesystem
namespace; they never replace your installed helper or invoke package managers.

```bash
./tests/install_helper_integration.sh
./tests/install_local_integration.sh
node --test tests/panel_consent.test.mjs tests/panel_reporting.test.mjs tests/install_reporting.test.mjs
./tests/reporting/run.sh
node tests/native-panel/run.cjs
node --test tests/native_harness.test.mjs
```

The native suite runs through the hermetic harness (`tests/native-panel/harness.cjs`):
a unique mode-0700 sandbox beneath `/tmp/$UID`, a preflight that aborts before
launch when any mutable endpoint escapes the sandbox, schema-validated JSONL
boundary traces, and cleanup on success, failure, and signals. Scenarios own
their behavioral assertions; the harness owns isolation, ordering, tracing, and
cleanup. `instances.qml` runs two unchanged production Panel instances across a
deterministic helper-dispatch barrier. `KEEP_STAGE=1` preserves the sandbox for
inspection; artifacts are otherwise disposed on every exit path.

The local installer tests seed interrupted transaction states (marker phase,
backup, target payloads) and assert the recovery decision table: a missing
named backup is refused without deleting the restored prior plugin, and only a
proven first-install marker removes an installed target. A rollback that has
restored the payload but not yet reconciled the plugin registry is recorded in
a durable rollback-registry-pending phase; recovery resumes it without
renaming or deleting payload files, and the marker is consumed only after the
recorded enabled/absent state is verified.

The consent tests model destructive Replace/Delete confirmation as a one-use
capability: arming captures the target, the accepted launch consumes both
tokens synchronously, and no failure, timeout, recovery handoff, or unrelated
operation leaves a reusable token behind. The native panel scenario drives the
production request/confirm path against failing and succeeding fake helpers
and counts destructive invocations.

Reporting tests also require Qt's `qmltestrunner`; native tests require the
installed Omarchy QML components and Quickshell. See the
[reporting checks](../tests/reporting/README.md) and
[native panel checks](../tests/native-panel/README.md).

To compile the real pinned Hyprloom source and validate it through the full
native panel, with temporary helper storage and a fake compositor:

```bash
DESKLOOM_TEST_REAL_CARGO=1 ./tests/install_helper_integration.sh
```

This opt-in test clones the sibling `../hyprloom` checkout, checks out the pinned
commit in the temporary clone, and downloads Cargo dependencies. Set
`DESKLOOM_HYPRLOOM_SOURCE` if the repository lives elsewhere. The built helper,
its genuine marker, and its test snapshots stay isolated from your live files.

After publishing the pinned revision, verify the public Git installation path
without a local source override:

```bash
DESKLOOM_TEST_REAL_CARGO=1 DESKLOOM_TEST_REMOTE_CARGO=1 ./tests/install_helper_integration.sh
```

This mode downloads the pinned repository directly from GitHub and performs the
same installation, repeat-install, and native panel checks in isolation.

To test an already installed matching helper:

```bash
HYPRLOOM_BIN="$HOME/.local/bin/hyprloom" node --test tests/cli_report_contract.test.mjs
DESKLOOM_TEST_INSTALLED_HELPER=1 DESKLOOM_TEST_HELPER_ROOT="$HOME/.local" node tests/native-panel/run.cjs
node --test tests/native_harness.test.mjs
```

The native suite runs through the hermetic harness (`tests/native-panel/harness.cjs`):
a unique mode-0700 sandbox beneath `/tmp/$UID`, a preflight that aborts before
launch when any mutable endpoint escapes the sandbox, schema-validated JSONL
boundary traces, and cleanup on success, failure, and signals. Scenarios own
their behavioral assertions; the harness owns isolation, ordering, tracing, and
cleanup. `instances.qml` runs two unchanged production Panel instances across a
deterministic helper-dispatch barrier. `KEEP_STAGE=1` preserves the sandbox for
inspection; artifacts are otherwise disposed on every exit path.

The native check preserves production command construction and readiness checks;
it substitutes executables/storage outside that boundary. Old installed pins
are intentionally not accepted by a plugin requiring a new source revision.

## Inspect the running plugin

```bash
omarchy-shell thethracian.deskloom.DP-1 status
```

Replace `DP-1` with your monitor name (URL-encoded if necessary). Diagnostics
include the loaded component URL, plugin/helper versions, readiness, snapshot
list state/count, popup open/mapped state, name-field focus, and retained report
counts. They expose no window titles or typed names and
do not start helper operations. Long operation errors remain selectable and
scrollable in the panel; a failed listing is not an empty snapshot collection.

## Publish an installable revision

Runtime code ships as a content-addressed bundle. After changing any runtime
file (Panel.qml, RestoreReport.js, RestoreReportView.qml, RestoreReportPopup.qml),
repackage the public artifact before committing so `omarchy plugin update`
picks up a fresh component URL without a shell restart:

```bash
./package-plugin.sh . .
./package-plugin.sh --check .
git add manifest.json
git add -f "$(dirname "$(jq -r .entryPoints.barWidget manifest.json)")"
```

The command discovers the declared local import closure, computes the bundle
identity from all shipped bytes, modes, and paths, and rewrites the manifest
atomically. The active bundle must be committed with the manifest; `runtime/`
is ignored by default. CI validates the bundle from a fresh checkout and
compares its identity with the current panel sources. Old runtime/ bundles
are kept locally so a Git rollback still has its
matching bytes; prune superseded bundles only when no in-flight install can
need them.



Publish the pinned Hyprloom commit before the Deskloom change that requires it.
Keep `expected_source_commit` and `expected_version` in `install-helper.sh` aligned
with `helperSourceCommit` and `helperVersion` in `Panel.qml`; tests check the pair.
The current development pin is a real commit in the Hyprloom repository, not a
release tag. No AUR recipe or crates.io publication is needed.

The public plugin URL is `https://github.com/stefan-vatov/deskloom.git`.
Omarchy clones it and enables the widget; it does not interpret this README or
execute installer hooks. Dependency installation remains an explicit user action.
