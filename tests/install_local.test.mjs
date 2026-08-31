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
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-install-local-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const configRoot = path.join(root, "config");
  const stateDir = path.join(root, "state");
  const runDir = path.join(root, "run");
  const bin = path.join(root, "bin");
  fs.mkdirSync(bin, { recursive: true });
  const calls = path.join(root, "omarchy.jsonl");

  const fakeOmarchy = `#!${process.execPath}
const fs = require("node:fs");
fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.argv[2] === "plugin" && process.argv[3] === "list") {
  process.stdout.write(process.env.TEST_PLUGIN_LIST ?? '[{"id":"thethracian.deskloom","enabled":true}]');
}
process.exit(process.env.TEST_OMARCHY_FAIL === "1" ? 1 : 0);
`;
  const fakeShell = `#!${process.execPath}
const fs = require("node:fs");
fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(["omarchy-shell", ...process.argv.slice(2)]) + "\\n");
if (process.env.TEST_KILL_AT_RESCAN === "1" && process.argv.includes("rescanPlugins")) {
  process.kill(process.ppid, "SIGKILL");
}
process.exit(0);
`;
  fs.writeFileSync(path.join(bin, "omarchy"), fakeOmarchy, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "omarchy-shell"), fakeShell, { mode: 0o755 });

  const backupRoot = path.join(configRoot, "omarchy", ".deskloom-rollback");
  const marker = path.join(backupRoot, "transaction");
  const target = path.join(configRoot, "omarchy", "plugins", "thethracian.deskloom");

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

  function run(extra = {}) {
    return spawnSync("/usr/bin/bwrap", [
      "--unshare-all", "--die-with-parent", "--new-session",
      "--ro-bind", "/", "/", "--bind", root, root,
      "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
      "/bin/bash", installer,
    ], {
      env: {
        PATH: `${bin}:/usr/bin:/bin`,
        XDG_CONFIG_HOME: configRoot,
        XDG_STATE_HOME: stateDir,
        XDG_RUNTIME_DIR: runDir,
        TEST_CALLS: calls,
        ...extra,
      },
      encoding: "utf8", timeout: 60000,
    });
  }

  return { root, backupRoot, marker, target, seedMarker, seedTarget, seedBackup, snapshot, readCalls, run };
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
  const result = f.run({ TEST_OMARCHY_FAIL: "1", ...extra });
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

for (const phase of ["rollback-registry-pending", "phase-from-the-future"]) {
  test(`recovery refuses an unrecognized future phase (${phase}) without mutating anything`, t => {
    const f = fixture(t);
    f.seedMarker(phase, "deskloom.old.77");
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

test("a hard kill during recovery rescan converges to a safe refusal on later runs", t => {
  const f = fixture(t);
  f.seedMarker("installed", "deskloom.old.77");
  f.seedTarget({ "Panel.qml": "new build\n" });
  f.seedBackup();

  const killed = f.run({ TEST_KILL_AT_RESCAN: "1" });
  assert.notEqual(killed.status, 0);
  assert.equal(fs.readFileSync(path.join(f.target, "UNIQUE_OLD.txt"), "utf8"), OLD_SENTINEL);
  assert.equal(fs.existsSync(path.join(f.backupRoot, "deskloom.old.77")), false);
  assert.equal(fs.existsSync(f.marker), true, "marker survives the kill");
  const markerAfterKill = fs.readFileSync(f.marker);
  const targetAfterKill = f.snapshot(f.target);

  for (let attempt = 0; attempt < 2; attempt++) {
    const refused = f.run();
    assert.notEqual(refused.status, 0, refused.stderr);
    assert.match(refused.stderr, /backup/i);
    assert.deepEqual(f.snapshot(f.target), targetAfterKill);
    assert.deepEqual(fs.readFileSync(f.marker), markerAfterKill);
  }
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
