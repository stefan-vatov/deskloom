import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("../", import.meta.url));
const installer = path.join(project, "install-local.sh");
const gate = path.join(project, "compile-gate.sh");
const uid = typeof process.getuid === "function" ? process.getuid() : 1000;

// The compile gate runs the real packager output through qmllint and the
// production loader inside a private offline namespace. Every mutable path
// (config, state, runtime dir, /tmp) lives inside the fixture root and the
// omarchy commands are fakes on PATH, so a sandbox run cannot touch the host
// install. /tmp is bound to <root>/tmp so the gate's probe directory under
// /tmp/$UID stays observable from the host after the namespace is gone.
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-compile-gate-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, "home");
  const configRoot = path.join(home, ".config");
  const stateDir = path.join(root, "state");
  const runDir = path.join(root, "run");
  const bin = path.join(root, "bin");
  const tmpRoot = path.join(root, "tmp");
  fs.mkdirSync(bin, { recursive: true });
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(tmpRoot, { recursive: true });
  const calls = path.join(root, "omarchy.jsonl");

  const fakeOmarchy = `#!${process.execPath}
const fs = require("node:fs");
fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.env.TEST_OMARCHY_FAIL_SUBSTR && process.argv.slice(2).join(" ").includes(process.env.TEST_OMARCHY_FAIL_SUBSTR)) process.exit(1);
if (process.argv[2] === "plugin" && process.argv[3] === "list") {
  process.stdout.write('[{"id":"thethracian.deskloom","enabled":true}]');
}
process.exit(0);
`;
  const fakeShell = `#!${process.execPath}
const fs = require("node:fs");
fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(["omarchy-shell", ...process.argv.slice(2)]) + "\\n");
if (process.argv[3] === "status") {
  const entry = JSON.parse(fs.readFileSync(process.env.TEST_TARGET_DIR + "/manifest.json", "utf8")).entryPoints.barWidget;
  process.stdout.write(JSON.stringify({ componentUrl: "file://" + process.env.TEST_TARGET_DIR + "/" + entry }));
  process.exit(0);
}
const targetExists = fs.existsSync(process.env.TEST_TARGET_DIR);
fs.writeFileSync(process.env.TEST_REGISTRY, targetExists ? "registered\\n" : "unregistered\\n");
process.exit(0);
`;
  const fakeHyprctl = `#!${process.execPath}
process.stdout.write(JSON.stringify([{ name: "DP-1" }]));
`;
  fs.writeFileSync(path.join(bin, "omarchy"), fakeOmarchy, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "omarchy-shell"), fakeShell, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "hyprctl"), fakeHyprctl, { mode: 0o755 });

  const target = path.join(configRoot, "omarchy", "plugins", "thethracian.deskloom");
  const backupRoot = path.join(configRoot, "omarchy", ".deskloom-rollback");
  const marker = path.join(backupRoot, "transaction");
  const registry = path.join(root, "registry");
  fs.writeFileSync(registry, "registered\n");

  function seedCheckout(dir) {
    fs.mkdirSync(path.join(dir, ".git"), { recursive: true });
    for (const name of [
      "install-local.sh", "install-helper.sh", "package-plugin.sh", "compile-gate.sh",
      "manifest.json", "README.md",
      "Panel.qml", "RestoreReport.js", "RestoreReportView.qml", "RestoreReportPopup.qml",
    ]) {
      fs.copyFileSync(path.join(project, name), path.join(dir, name));
    }
    fs.writeFileSync(path.join(dir, ".git", "HEAD"), "ref: refs/heads/main\n");
  }

  function readCalls() {
    if (!fs.existsSync(calls)) return [];
    return fs.readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
  }

  function run(extra = {}, scriptPath = installer, args = []) {
    return spawnSync("/usr/bin/bwrap", [
      "--unshare-all", "--die-with-parent", "--new-session",
      "--ro-bind", "/", "/",
      // /tmp is replaced first so it cannot mask the fixture root (which
      // mkdtemp places under the host /tmp); the root bind re-exposes it.
      "--bind", tmpRoot, "/tmp",
      "--bind", root, root,
      "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
      "/bin/bash", scriptPath, ...args,
    ], {
      env: {
        PATH: `${bin}:/usr/bin:/bin`,
        HOME: home,
        XDG_STATE_HOME: stateDir,
        XDG_RUNTIME_DIR: runDir,
        TEST_CALLS: calls,
        TEST_REGISTRY: registry,
        TEST_TARGET_DIR: target,
        ...extra,
      },
      encoding: "utf8", timeout: 120000,
    });
  }

  // Builds a real staged plugin on the host side with the same packager the
  // installer uses. `broken` injects a QML syntax error into the staged
  // runtime bundle.
  function stageFromCheckout(checkout, { broken = false } = {}) {
    const staged = path.join(root, `staged-${Math.random().toString(36).slice(2, 8)}`);
    fs.mkdirSync(staged);
    const packaged = spawnSync("/bin/bash", [
      path.join(project, "package-plugin.sh"), checkout, staged,
    ], { encoding: "utf8" });
    assert.equal(packaged.status, 0, packaged.stderr);
    if (broken) {
      const entry = JSON.parse(fs.readFileSync(path.join(staged, "manifest.json"), "utf8")).entryPoints.barWidget;
      fs.appendFileSync(path.join(staged, entry), "\nfunction gateBroken( {\n");
    }
    return staged;
  }

  function assertProbeCleaned() {
    assert.equal(fs.existsSync(path.join(tmpRoot, String(uid))), false,
      "the gate must leave no probe directory under /tmp/$UID");
  }

  return { root, home, configRoot, target, backupRoot, marker, registry, seedCheckout, readCalls, run, stageFromCheckout, assertProbeCleaned };
}

test("a broken staged QML makes the installer abort before creating the target", t => {
  const f = fixture(t);
  const checkout = path.join(f.root, "checkout");
  f.seedCheckout(checkout);
  fs.appendFileSync(path.join(checkout, "RestoreReportView.qml"), "\nfunction gateBroken( {\n");

  const result = f.run({}, path.join(checkout, "install-local.sh"));

  assert.notEqual(result.status, 0, result.stderr);
  const lines = result.stderr.trim().split("\n").filter(Boolean);
  assert.match(lines[lines.length - 1], /compile-gate: FAIL class=lint-error/,
    "the gate diagnostic must be the last stderr line");
  assert.equal(fs.existsSync(f.target), false, "the target must never be created");
  assert.equal(fs.existsSync(f.marker), false, "no transaction marker may be created");
  if (fs.existsSync(f.backupRoot)) {
    assert.deepEqual(fs.readdirSync(f.backupRoot).filter(name => name.startsWith("deskloom.old.")), [],
      "no rollback artifacts may be created");
  }
  assert.deepEqual(f.readCalls(), [], "omarchy must not run before the gate passes");
  f.assertProbeCleaned();
});

test("a good staged bundle passes the gate and the install succeeds", t => {
  const f = fixture(t);
  const checkout = path.join(f.root, "checkout");
  f.seedCheckout(checkout);

  const result = f.run({}, path.join(checkout, "install-local.sh"));

  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(path.join(f.target, "manifest.json")));
  assert.ok(fs.existsSync(path.join(f.target, "runtime")));
  assert.ok(f.readCalls().some(call => call.includes("rescanPlugins")));
  f.assertProbeCleaned();
});

test("the gate cleans its probe directory on pass and on failure", t => {
  const f = fixture(t);
  const checkout = path.join(f.root, "checkout");
  f.seedCheckout(checkout);

  const good = f.stageFromCheckout(checkout);
  const passed = f.run({}, gate, [good]);
  assert.equal(passed.status, 0, passed.stderr);
  assert.match(passed.stderr, /lint start files=/);
  assert.match(passed.stderr, /lint finish elapsed_ms=\d+ outcome=pass/);
  assert.match(passed.stderr, /load start loader=/);
  assert.match(passed.stderr, /load finish elapsed_ms=\d+ outcome=pass/);
  assert.match(passed.stderr, /compile-gate: pass lint_ms=\d+ load_ms=\d+/);
  f.assertProbeCleaned();

  const broken = f.stageFromCheckout(checkout, { broken: true });
  const failed = f.run({}, gate, [broken]);
  assert.notEqual(failed.status, 0, failed.stderr);
  const lines = failed.stderr.trim().split("\n").filter(Boolean);
  assert.match(lines[lines.length - 1], /compile-gate: FAIL class=lint-error/);
  assert.doesNotMatch(failed.stderr, /compile-gate: load start/,
    "a lint failure must abort before the load phase");
  f.assertProbeCleaned();
});
