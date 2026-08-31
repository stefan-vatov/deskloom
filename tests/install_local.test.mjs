import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("../", import.meta.url));
const installer = path.join(project, "install-local.sh");

const OLD_SENTINEL = "prior plugin payload unique to the previous install\n";

// Runs the real installer in a private offline namespace. Every mutable path
// (config, state, runtime dir) lives inside the fixture root and the omarchy
// commands are fakes on PATH, so a sandbox run cannot touch the host install.
// Seeds a minimal fake checkout: enough for the installer to identify its
// own source directory and, for the disjoint control, to complete a real
// install. Sentinels prove nothing destroyed it.
function seedCheckout(dir) {
  fs.mkdirSync(path.join(dir, ".git"), { recursive: true });
  for (const name of [
    "install-local.sh", "install-helper.sh", "package-plugin.sh", "compile-gate.sh", "manifest.json", "README.md",
    "Panel.qml", "RestoreReport.js", "RestoreReportView.qml", "RestoreReportPopup.qml",
  ]) {
    fs.copyFileSync(path.join(project, name), path.join(dir, name));
  }
  fs.writeFileSync(path.join(dir, "UNCOMMITTED.txt"), "unpublished work\n");
  fs.writeFileSync(path.join(dir, ".git", "HEAD"), "ref: refs/heads/main\n");
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-install-local-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, "home");
  const configRoot = path.join(home, ".config");
  const stateDir = path.join(root, "state");
  const runDir = path.join(root, "run");
  const bin = path.join(root, "bin");
  const tmpRoot = path.join(root, "tmp");
  fs.mkdirSync(bin, { recursive: true });
  fs.mkdirSync(tmpRoot, { recursive: true });
  fs.mkdirSync(home, { recursive: true });
  const calls = path.join(root, "omarchy.jsonl");

  const fakeOmarchy = `#!${process.execPath}
const fs = require("node:fs");
fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(process.argv.slice(2)) + "\\n");
const args = process.argv.slice(2).join(" ");
if (process.env.TEST_OMARCHY_FAIL_SUBSTR && args.includes(process.env.TEST_OMARCHY_FAIL_SUBSTR)) process.exit(1);
if (process.argv[2] === "plugin" && process.argv[3] === "list") {
  let count = 0;
  try { count = parseInt(fs.readFileSync(process.env.TEST_LIST_COUNT, "utf8").trim() || "0", 10); } catch {}
  count += 1;
  try { fs.writeFileSync(process.env.TEST_LIST_COUNT, String(count)); } catch {}
  let registered = true;
  try { registered = fs.readFileSync(process.env.TEST_REGISTRY, "utf8").trim() === "registered"; } catch {}
  const empty = process.env.TEST_LIST_EMPTY_FIRST_N && count <= parseInt(process.env.TEST_LIST_EMPTY_FIRST_N, 10);
  if (empty || !registered) {
    process.stdout.write("[]");
  } else {
    process.stdout.write(process.env.TEST_PLUGIN_LIST ?? '[{"id":"thethracian.deskloom","enabled":true}]');
  }
}
process.exit(process.env.TEST_OMARCHY_FAIL === "1" ? 1 : 0);
`;
  const fakeShell = `#!${process.execPath}
const fs = require("node:fs");
fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(["omarchy-shell", ...process.argv.slice(2)]) + "\\n");
if (process.argv.includes("rescanPlugins")) {
  if (process.env.TEST_KILL_AT_RESCAN === "1") process.kill(process.ppid, "SIGKILL");
  if (process.env.TEST_FAIL_RESCAN === "1") process.exit(1);
  const targetExists = fs.existsSync(process.env.TEST_TARGET_DIR);
  fs.writeFileSync(process.env.TEST_REGISTRY, targetExists ? "registered\\n" : "unregistered\\n");
}
process.exit(0);
`;
  fs.writeFileSync(path.join(bin, "omarchy"), fakeOmarchy, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "omarchy-shell"), fakeShell, { mode: 0o755 });

  const backupRoot = path.join(configRoot, "omarchy", ".deskloom-rollback");
  const marker = path.join(backupRoot, "transaction");
  const target = path.join(configRoot, "omarchy", "plugins", "thethracian.deskloom");
  const registry = path.join(root, "registry");
  fs.writeFileSync(registry, "registered\n");

  function writeTree(base, files) {
    for (const [name, content] of Object.entries(files)) {
      const file = path.join(base, name);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, content);
    }
  }

  function seedMarker(phase, backupName, enabled = "true") {
    fs.mkdirSync(backupRoot, { recursive: true });
    fs.writeFileSync(marker, `${phase}\n${backupName}\n${enabled}\n`, { mode: 0o600 });
  }

  function seedTarget(files = { "UNIQUE_OLD.txt": OLD_SENTINEL }) {
    fs.mkdirSync(target, { recursive: true });
    fs.chmodSync(target, 0o700);
    writeTree(target, files);
  }

  function seedBackup(name = "deskloom.old.77", files = { "UNIQUE_OLD.txt": OLD_SENTINEL }) {
    const dir = path.join(backupRoot, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.chmodSync(dir, 0o700);
    writeTree(dir, files);
  }

  function snapshot(base) {
    const files = {};
    const walk = (dir, prefix = "") => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
        const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
        if (entry.isDirectory()) walk(path.join(dir, entry.name), rel);
        else files[rel] = fs.readFileSync(path.join(dir, entry.name));
      }
    };
    walk(base);
    return files;
  }

  function readCalls() {
    if (!fs.existsSync(calls)) return [];
    return fs.readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
  }

  function run(extra = {}, scriptPath = installer) {
    return spawnSync("/usr/bin/bwrap", [
      "--unshare-all", "--die-with-parent", "--new-session",
      // /tmp is replaced first so it cannot mask the fixture root (which
      // mkdtemp places under the host /tmp); the root bind re-exposes it.
      // The sandbox needs a writable /tmp so the compile gate can build its
      // probe directory under /tmp/$UID.
      "--ro-bind", "/", "/", "--bind", tmpRoot, "/tmp", "--bind", root, root,
      "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
      "/bin/bash", scriptPath,
    ], {
      env: {
        PATH: `${bin}:/usr/bin:/bin`,
        HOME: home,
        XDG_STATE_HOME: stateDir,
        XDG_RUNTIME_DIR: runDir,
        TEST_CALLS: calls,
        TEST_REGISTRY: registry,
        TEST_TARGET_DIR: target,
        TEST_LIST_COUNT: "/run/list-count",
        ...extra,
      },
      encoding: "utf8", timeout: 60000,
    });
  }

  return { root, home, configRoot, stateDir, backupRoot, marker, target, registry, seedMarker, seedTarget, seedBackup, seedCheckout, snapshot, readCalls, run };
}

test("recovery refuses to delete the restored prior plugin when a named backup is missing", t => {
  const f = fixture(t);
  f.seedMarker("installed", "deskloom.old.77");
  f.seedTarget();
  f.seedBackup();
  fs.rmSync(path.join(f.backupRoot, "deskloom.old.77"), { recursive: true });
  const markerBefore = fs.readFileSync(f.marker);
  const targetBefore = f.snapshot(f.target);

  const result = f.run();

  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /backup/i);
  assert.deepEqual(f.snapshot(f.target), targetBefore);
  assert.deepEqual(fs.readFileSync(f.marker), markerBefore);
  assert.deepEqual(f.readCalls(), []);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), false);
});

// A run aborted at the first main-flow omarchy call (plugin validate) stops
// before the installer mutates the target, so a follow-up inspection observes
// exactly what recovery did. The sentinel payload is unique to the prior
// install, so its presence proves which copy the target holds.
function abortedRun(f, extra = {}) {
  const result = f.run({ TEST_OMARCHY_FAIL_SUBSTR: "validate", ...extra });
  assert.notEqual(result.status, 0, result.stderr);
  return result;
}

test("recovery with a present named backup restores the prior plugin", t => {
  const f = fixture(t);
  f.seedMarker("installed", "deskloom.old.77");
  f.seedTarget({ "Panel.qml": "new broken build\n" });
  f.seedBackup();

  abortedRun(f);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), false);
  assert.equal(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")).length, 0);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(f.readCalls().some(call => call.includes("rescanPlugins")));
  assert.ok(f.readCalls().some(call => call[0] === "plugin" && call[1] === "enable"));
});

test("recovery with a present named backup and a missing target restores the prior plugin", t => {
  const f = fixture(t);
  f.seedMarker("installed", "deskloom.old.77");
  f.seedBackup();

  abortedRun(f);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), false);
  assert.equal(fs.existsSync(f.marker), false);

  assert.equal(f.run().status, 0, "the next run converges to a fresh install");
});

test("recovery removes an installed target only for a proven first install", t => {
  const f = fixture(t);
  f.seedMarker("installed", "none");
  f.seedTarget({ "Panel.qml": "partial first install\n" });

  const result = f.run();

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(f.target, "Panel.qml")), false);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(f.readCalls().some(call => call.includes("rescanPlugins")));
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

test("recovery leaves nothing to do for a first-install marker without a target", t => {
  const f = fixture(t);
  f.seedMarker("installed", "none");

  const result = f.run();

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

for (const phase of ["prepared", "backed-up"]) {
  test(`recovery keeps the installed plugin when a ${phase} transaction is interrupted before the backup move`, t => {
    const f = fixture(t);
    f.seedMarker(phase, "deskloom.old.77");
    f.seedTarget();

    abortedRun(f);
    assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
    assert.equal(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")).length, 0);
    assert.equal(fs.existsSync(f.marker), false);
  });

  test(`recovery restores a stale ${phase} backup over the installed plugin`, t => {
    const f = fixture(t);
    f.seedMarker(phase, "deskloom.old.77");
    f.seedTarget({ "Panel.qml": "live target\n" });
    f.seedBackup();

    abortedRun(f);
    assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
    assert.equal(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")).length, 0);
    assert.equal(fs.existsSync(f.marker), false);
  });
}

test("recovery discards a committed backup and keeps the new install", t => {
  const f = fixture(t);
  f.seedMarker("committed", "deskloom.old.77");
  f.seedTarget({ "Panel.qml": "new committed build\n" });
  f.seedBackup();

  abortedRun(f);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), false);
  assert.equal(fs.existsSync(path.join(f.target, "UNIQUE_OLD.txt")), false);
  assert.equal(fs.existsSync(f.marker), false);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

test("recovery restores a committed backup when the target is missing", t => {
  const f = fixture(t);
  f.seedMarker("committed", "deskloom.old.77");
  f.seedBackup();

  abortedRun(f);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")).length, 0);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(f.readCalls().some(call => call.includes("rescanPlugins")));
});

test("recovery refuses an unrecognized future phase without mutating anything", t => {
  const f = fixture(t);
  f.seedMarker("phase-from-the-future", "deskloom.old.77");
  f.seedTarget();
  const markerBefore = fs.readFileSync(f.marker);
  const targetBefore = f.snapshot(f.target);

  const result = f.run();

  assert.notEqual(result.status, 0, result.stderr);
  assert.deepEqual(f.snapshot(f.target), targetBefore);
  assert.deepEqual(fs.readFileSync(f.marker), markerBefore);
  assert.deepEqual(f.readCalls(), []);
});

for (const [name, markerText] of [
  ["unsafe backup name", "installed\n../escape\ntrue\n"],
  ["four-field marker", "installed\ndeskloom.old.77\ntrue\nextra\n"],
  ["invalid enabled state", "installed\nnone\nmaybe\n"],
]) {
  test(`recovery refuses a malformed marker (${name}) without mutating anything`, t => {
    const f = fixture(t);
    fs.mkdirSync(f.backupRoot, { recursive: true });
    fs.writeFileSync(f.marker, markerText, { mode: 0o600 });
    f.seedTarget();
    const markerBefore = fs.readFileSync(f.marker);
    const targetBefore = f.snapshot(f.target);

    const result = f.run();

    assert.notEqual(result.status, 0, result.stderr);
    assert.deepEqual(f.snapshot(f.target), targetBefore);
    assert.deepEqual(fs.readFileSync(f.marker), markerBefore);
    assert.deepEqual(f.readCalls(), []);
  });
}

test("a hard kill after the durable rollback phase converges on the next run", t => {
  const f = fixture(t);
  f.seedMarker("installed", "deskloom.old.77");
  f.seedTarget({ "Panel.qml": "new build\n" });
  f.seedBackup();

  const killed = f.run({ TEST_KILL_AT_RESCAN: "1" });
  assert.notEqual(killed.status, 0);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), false);
  assert.equal(fs.existsSync(f.marker), true, "durable phase marker survives the kill");
  assert.match(fs.readFileSync(f.marker, "utf8"), /^rollback-registry-pending\n/);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

test("a hard kill during first-install recovery converges to a clean reinstall", t => {
  const f = fixture(t);
  f.seedMarker("installed", "none");
  f.seedTarget({ "Panel.qml": "partial first install\n" });

  const killed = f.run({ TEST_KILL_AT_RESCAN: "1" });
  assert.notEqual(killed.status, 0);
  assert.equal(fs.existsSync(f.target), false);
  assert.equal(fs.existsSync(f.marker), true);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

test("rollback-registry-pending reconciles the registry without touching the restored payload", t => {
  const f = fixture(t);
  f.seedMarker("rollback-registry-pending", "deskloom.old.77");
  f.seedTarget();

  const result = f.run({ TEST_OMARCHY_FAIL_SUBSTR: "validate" });

  assert.notEqual(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(f.marker), false, "marker is consumed only after the registry converges");
  assert.equal(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")).length, 0);
  assert.ok(f.readCalls().some(call => call.includes("rescanPlugins")));
  assert.ok(f.readCalls().some(call => call[0] === "plugin" && call[1] === "enable"));
});

test("rollback-registry-pending for a first install verifies the plugin is absent", t => {
  const f = fixture(t);
  f.seedMarker("rollback-registry-pending", "none", "unknown");
  const result = f.run({ TEST_OMARCHY_FAIL_SUBSTR: "validate", TEST_PLUGIN_LIST: "[]" });

  assert.notEqual(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.target), false);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(f.readCalls().some(call => call.includes("rescanPlugins")));
  assert.ok(!f.readCalls().some(call => call[0] === "plugin" && ["enable", "disable"].includes(call[1])));
});

test("rollback-registry-pending restores a disabled prior state", t => {
  const f = fixture(t);
  f.seedMarker("rollback-registry-pending", "deskloom.old.77", "false");
  f.seedTarget();

  const result = f.run({
    TEST_OMARCHY_FAIL_SUBSTR: "validate",
    TEST_PLUGIN_LIST: '[{"id":"thethracian.deskloom","enabled":false}]',
  });

  assert.notEqual(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(f.readCalls().some(call => call[0] === "plugin" && call[1] === "disable"));
});

test("a failing rescan retains the rollback marker until reconciliation converges", t => {
  const f = fixture(t);
  f.seedMarker("rollback-registry-pending", "deskloom.old.77");
  f.seedTarget();
  const markerBefore = fs.readFileSync(f.marker);
  const targetBefore = f.snapshot(f.target);

  const failed = f.run({ TEST_FAIL_RESCAN: "1" });
  assert.notEqual(failed.status, 0, failed.stderr);
  assert.match(failed.stderr, /marker/i);
  assert.deepEqual(fs.readFileSync(f.marker), markerBefore);
  assert.deepEqual(f.snapshot(f.target), targetBefore);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.marker), false);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

test("a failing registry listing retains the rollback marker until it converges", t => {
  const f = fixture(t);
  f.seedMarker("rollback-registry-pending", "deskloom.old.77");
  f.seedTarget();
  const markerBefore = fs.readFileSync(f.marker);

  const failed = f.run({ TEST_LIST_EMPTY_FIRST_N: "999" });
  assert.notEqual(failed.status, 0, failed.stderr);
  assert.deepEqual(fs.readFileSync(f.marker), markerBefore);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.marker), false);
});

test("rollback-registry-pending with a remaining backup refuses without mutating anything", t => {
  const f = fixture(t);
  f.seedMarker("rollback-registry-pending", "deskloom.old.77");
  f.seedTarget();
  f.seedBackup();
  const markerBefore = fs.readFileSync(f.marker);
  const targetBefore = f.snapshot(f.target);

  const result = f.run();

  assert.notEqual(result.status, 0, result.stderr);
  assert.deepEqual(f.snapshot(f.target), targetBefore);
  assert.deepEqual(fs.readFileSync(f.marker), markerBefore);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), true);
  assert.deepEqual(f.readCalls(), []);
});

test("a failed registration rolls back and durably records the pending registry state", t => {
  const f = fixture(t);
  f.seedTarget();

  const failed = f.run({ TEST_LIST_EMPTY_FIRST_N: "41" });
  assert.notEqual(failed.status, 0, failed.stderr);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(f.marker), false, "registry reconciliation completed inside the failing run");
  assert.equal(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")).length, 0);

  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

function assertNoSideEffects(f) {
  assert.equal(fs.existsSync(path.join(f.stateDir, "deskloom")), false, "no install lock is created");
  const leftovers = fs.existsSync(f.configRoot)
    ? fs.readdirSync(f.configRoot).filter(name => name.startsWith(".thethracian.deskloom."))
    : [];
  assert.deepEqual(leftovers, [], "no staging directory is created");
  assert.equal(fs.existsSync(f.marker), false, "no transaction marker is created");
  assert.deepEqual(f.readCalls(), [], "no omarchy commands run");
}

test("refuses to install when the checkout is the live plugin target", t => {
  const f = fixture(t);
  seedCheckout(f.target);
  const before = f.snapshot(f.target);
  const script = path.join(f.target, "install-local.sh");

  const result = f.run({}, script);

  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /live plugin target/);
  assert.deepEqual(f.snapshot(f.target), before);
  assertNoSideEffects(f);
});

test("refuses to install through a symlink alias of the live target", t => {
  const f = fixture(t);
  const checkout = path.join(f.root, "checkout");
  seedCheckout(checkout);
  fs.mkdirSync(path.join(f.configRoot, "omarchy", "plugins"), { recursive: true });
  fs.symlinkSync(checkout, f.target);
  const before = f.snapshot(checkout);
  const script = path.join(checkout, "install-local.sh");

  const result = f.run({}, script);

  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /live plugin target/);
  assert.deepEqual(f.snapshot(checkout), before);
  assert.equal(fs.readlinkSync(f.target), checkout);
  assertNoSideEffects(f);
});

test("refuses to install when the live target sits inside the checkout", t => {
  const f = fixture(t);
  const checkout = path.join(f.root, "checkout");
  seedCheckout(checkout);
  const nestedHome = path.join(checkout, "home");
  const before = f.snapshot(checkout);
  const script = path.join(checkout, "install-local.sh");

  const result = f.run({ HOME: nestedHome }, script);

  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /live plugin target/);
  assert.deepEqual(f.snapshot(checkout), before);
  assertNoSideEffects({ ...f, configRoot: nestedHome + "/.config", marker: path.join(nestedHome, ".config", "omarchy", ".deskloom-rollback", "transaction"), readCalls: f.readCalls });
});

test("refuses to install from a checkout inside the live target", t => {
  const f = fixture(t);
  const nested = path.join(f.target, "checkout");
  seedCheckout(nested);
  const before = f.snapshot(f.target);
  const script = path.join(nested, "install-local.sh");

  const result = f.run({}, script);

  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /live plugin target/);
  assert.deepEqual(f.snapshot(f.target), before);
  assertNoSideEffects(f);
});

test("refuses to install through a lexical dot-segment alias of the live target", t => {
  const f = fixture(t);
  seedCheckout(f.target);
  const before = f.snapshot(f.target);
  const script = path.join(f.configRoot, "omarchy", "plugins", ".", "thethracian.deskloom", "install-local.sh");

  const result = f.run({}, script);

  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /live plugin target/);
  assert.deepEqual(f.snapshot(f.target), before);
  assertNoSideEffects(f);
});

test("installs normally from a disjoint checkout", t => {
  const f = fixture(t);
  const checkout = path.join(f.root, "checkout");
  seedCheckout(checkout);
  const before = f.snapshot(checkout);

  const result = f.run({}, path.join(checkout, "install-local.sh"));

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(f.snapshot(checkout), before, "the source checkout is untouched");
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
});

test("installs into the canonical home registry even with XDG_CONFIG_HOME set", t => {
  const f = fixture(t);
  const xdg = path.join(f.root, "xdg");
  fs.mkdirSync(xdg, { recursive: true });

  const result = f.run({ XDG_CONFIG_HOME: xdg });

  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")), "canonical target must receive the install");
  assert.equal(fs.existsSync(path.join(xdg, "omarchy")), false, "XDG config dir must stay untouched");
  assert.equal(fs.existsSync(path.join(xdg, ".deskloom-rollback")), false, "no rollback dir under XDG");
});

test("leaves a ghost install under a noncanonical XDG directory untouched but says so", t => {
  const f = fixture(t);
  const xdg = path.join(f.root, "xdg");
  const ghost = path.join(xdg, "omarchy", "plugins", "thethracian.deskloom");
  fs.mkdirSync(ghost, { recursive: true });
  fs.writeFileSync(path.join(ghost, "GHOST.txt"), "stale copy\n");
  const before = f.snapshot(ghost);

  const result = f.run({ XDG_CONFIG_HOME: xdg });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /XDG_CONFIG_HOME/);
  assert.deepEqual(f.snapshot(ghost), before, "the ghost install must be left untouched");
});
