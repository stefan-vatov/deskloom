# Native Panel regression

Run `node tests/native-panel/run.cjs` from the repository root.

Requires Bubblewrap, Quickshell, QtTest, Node.js, and installed Omarchy
Commons/Ui. Each run uses private namespaces with no network, a read-only host
filesystem, isolated XDG directories, and offscreen Qt. HOME retains its actual
value; only the helper executable and marker are overlaid with test files in
the private mount namespace. No display, compositor, D-Bus, or shell-init
environment is passed. The default suite runs only the fake helper.

1. Observe same-URL component caching after a real subprocess rewrites a
   temporary QML file; verify a changed URL loads revision 2. Disable file
   watching in that isolated harness so a whole-engine reload cannot mask the
   cache behavior. Both filenames exist before loading; only bytes change.
2. Compile the original production Panel bytes without instantiating it.
   Duplicate handlers must fail this gate; the runner never repairs them.
3. Call the production command builder in QML for all six operations and
   literal special characters. This reproduces `[object Arguments]`; extracted
   JavaScript and an overridden command builder miss it.
4. Instantiate production Panel with real Commons/Ui, helper readiness,
   command construction, Process, and StdioCollector objects. No command
   builder is overridden. The mounted fake helper checks exact argv. Assert
   report rows, Last restore, save-and-refresh, retained snapshots after a
   failed save, and complete selectable/scrollable multiline diagnostics.
   Check collector ordering and read-only status. Login restore is disabled;
   installer and boot launch entry points throw if called.

Production files remain byte-identical in both stages; existing objectName
probes allow read-only lookup. Handlers and process collectors are unchanged.
The fake helper accepts readiness checks, list/recover, named synthetic
save/restore cases, and the temporary cache rewrite. Unknown commands fail
closed. Each Quickshell run
has a 15-second outer timeout; temporary files are removed on completion.

This checks Qt lifecycle and real pipe collection, not compositor focus or live
desktop restoration. Offscreen window-mask and unavailable Hyprland focus-grab
warnings are expected. A cache observation is reported rather than assuming
all future Qt/Quickshell versions must retain stale components. A successful
run exits zero and prints four `NATIVE_PASS` markers.

For the actual installed pinned CLI, also run:

```sh
DESKLOOM_TEST_INSTALLED_HELPER=1 node tests/native-panel/run.cjs
```

That adds a fifth run without overlaying the helper or marker. The real CLI
lists an old-format fixture, saves a new snapshot, and reports an existing
window through the unchanged production panel. Snapshot/config storage is
temporary; the fake compositor accepts only read queries and rejects all
dispatches. Assert persisted save contents and unchanged original preset bytes.
