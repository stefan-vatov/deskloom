import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("../", import.meta.url));
const packager = path.join(project, "package-plugin.sh");

const RUNTIME_FILES = ["Panel.qml", "RestoreReport.js", "RestoreReportView.qml", "RestoreReportPopup.qml"];

function sourceFixture(t, mutate = () => {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-package-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const source = path.join(root, "source");
  fs.mkdirSync(source);
  for (const file of [...RUNTIME_FILES, "manifest.json", "README.md", "install-helper.sh", "package-plugin.sh", "compile-gate.sh", "install-local.sh"])
    fs.copyFileSync(path.join(project, file), path.join(source, file));
  mutate(source);
  return { root, source };
}

function pack(t, source, extraArgs = []) {
  const staging = path.join(source, "..", `stage-${Math.random().toString(36).slice(2)}`);
  const result = spawnSync("/bin/bash", [packager, source, staging], { encoding: "utf8", timeout: 30000 });
  t.after(() => fs.rmSync(staging, { recursive: true, force: true }));
  return { result, staging };
}

function entryOf(staging) {
  return JSON.parse(fs.readFileSync(path.join(staging, "manifest.json"), "utf8")).entryPoints.barWidget;
}

test("packaging is deterministic and ships the complete declared closure", t => {
  const f = sourceFixture(t);
  const first = pack(t, f.source);
  assert.equal(first.result.status, 0, first.result.stderr);
  const second = pack(t, f.source);
  assert.equal(second.result.status, 0, second.result.stderr);
  assert.equal(entryOf(first.staging), entryOf(second.staging), "identical inputs must produce identical URLs");
  const bundle = path.join(first.staging, path.dirname(entryOf(first.staging)));
  for (const file of RUNTIME_FILES) {
    assert.deepEqual(
      fs.readFileSync(path.join(bundle, file)),
      fs.readFileSync(path.join(f.source, file)),
      `${file} must ship byte-identical`,
    );
  }
  assert.match(entryOf(first.staging), /^runtime\/[a-f0-9]{64}\/Panel\.qml$/);
});

test("packaging rewrites the staged manifest atomically and never mutates the source", t => {
  const f = sourceFixture(t);
  const manifestBefore = fs.readFileSync(path.join(f.source, "manifest.json"));
  const { result, staging } = pack(t, f.source);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readFileSync(path.join(f.source, "manifest.json")), manifestBefore);
  assert.match(entryOf(staging), /^runtime\//);
  assert.ok(fs.existsSync(path.join(staging, "README.md")));
  assert.ok(fs.existsSync(path.join(staging, "install-helper.sh")));
});

test("one changed runtime byte produces a new identity", t => {
  const f = sourceFixture(t);
  const before = pack(t, f.source);
  fs.appendFileSync(path.join(f.source, "RestoreReport.js"), "\n// changed\n");
  const after = pack(t, f.source);
  assert.notEqual(entryOf(after.staging), entryOf(before.staging), "a dependency byte change must move the URL");
  assert.equal(fs.existsSync(path.join(after.staging, path.dirname(entryOf(before.staging)))), false);
});

test("a permission mode change produces a new identity", t => {
  const f = sourceFixture(t);
  const before = pack(t, f.source);
  fs.chmodSync(path.join(f.source, "RestoreReport.js"), 0o600);
  const after = pack(t, f.source);
  assert.notEqual(entryOf(after.staging), entryOf(before.staging), "mode changes are part of component identity");
});

test("a declared import escaping the bundle root fails the package", t => {
  const f = sourceFixture(t, source => {
    fs.writeFileSync(path.join(source, "OUTSIDE.qml"), "import QtQuick\nItem {}\n");
    const panel = fs.readFileSync(path.join(source, "Panel.qml"), "utf8");
    fs.writeFileSync(path.join(source, "Panel.qml"), 'import "../OUTSIDE.qml"\n' + panel);
  });
  const { result } = pack(t, f.source);
  assert.notEqual(result.status, 0, "imports outside the bundle root must fail closed");
  assert.match(result.stderr, /escapes the bundle root/);
  assert.equal(fs.existsSync(path.join(f.source, "..")), true);
  const staging = fs.readdirSync(path.join(f.source, "..")).find(d => d.startsWith("stage-"));
  assert.equal(staging === undefined || fs.readdirSync(path.join(f.source, "..", staging)).length === 0,
    true, "no outside file may be copied into a bundle");
});

test("a declared local import that is missing fails the package with an actionable error", t => {
  const f = sourceFixture(t, source => {
    fs.appendFileSync(path.join(source, "Panel.qml"), "\n// import \"Missing.js\" as Missing\n");
    const text = fs.readFileSync(path.join(source, "Panel.qml"), "utf8");
    fs.writeFileSync(path.join(source, "Panel.qml"), text.replace("\n// import \"Missing.js\" as Missing\n", "\nimport \"Missing.js\" as Missing\n"));
  });
  const { result } = pack(t, f.source);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing\.js/);
});

test("check mode proves a published artifact matches its manifest and detects tampering", t => {
  const f = sourceFixture(t);
  const published = path.join(f.root, "published");
  fs.cpSync(pack(t, f.source).staging, published, { recursive: true });
  const ok = spawnSync("/bin/bash", [packager, "--check", published], { encoding: "utf8" });
  assert.equal(ok.status, 0, ok.stderr);

  const entry = entryOf(published);
  fs.appendFileSync(path.join(published, entry), "\n// tampered\n");
  const bad = spawnSync("/bin/bash", [packager, "--check", published], { encoding: "utf8" });
  assert.notEqual(bad.status, 0, "tampered published bytes must fail the check");
});

test("install-local ships the same identity as the standalone packager", t => {
  const f = sourceFixture(t);
  const bin = path.join(f.root, "bin");
  fs.mkdirSync(bin);
  const home = path.join(f.root, "home");
  fs.mkdirSync(home);
  const liveTarget = path.join(home, ".config/omarchy/plugins/thethracian.deskloom");
  // Minimal registry model: the shell lists exactly what exists on disk.
  fs.writeFileSync(path.join(bin, "omarchy"), `#!/bin/sh
case "$1 $2" in
  'plugin list')
    if [ -d '${liveTarget}' ]; then
      printf '%s\n' '[{"id":"thethracian.deskloom","enabled":true}]'
    else
      printf '%s\n' '[]'
    fi ;;
  *) exit 0 ;;
esac
`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "omarchy-shell"), `#!/bin/sh
# Answer the per-monitor acknowledgment probe with the live install's
# content-addressed component, exactly as the production shell would.
if [ "$2" = status ]; then
  entry=$(jq -r '.entryPoints.barWidget' '${liveTarget}/manifest.json' 2>/dev/null)
  jq -n --arg u "file://${liveTarget}/$entry" '{componentUrl: $u}'
fi
exit 0
`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "hyprctl"), `#!/bin/sh
printf '%s\n' '[{"name":"DP-1"}]'
`, { mode: 0o755 });
  const result = spawnSync("/usr/bin/bwrap", [
    "--unshare-all", "--die-with-parent", "--new-session",
    "--ro-bind", "/", "/", "--bind", f.root, f.root,
    "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
    "/bin/bash", path.join(f.source, "install-local.sh"),
  ], {
    env: { HOME: home, PATH: `${bin}:/usr/bin:/bin`, XDG_STATE_HOME: path.join(f.root, "state"), XDG_RUNTIME_DIR: path.join(f.root, "run") },
    encoding: "utf8", timeout: 60000,
  });
  assert.equal(result.status, 0, result.stderr);
  const installed = path.join(home, ".config/omarchy/plugins/thethracian.deskloom");
  const localEntry = JSON.parse(fs.readFileSync(path.join(installed, "manifest.json"), "utf8")).entryPoints.barWidget;
  const packaged = pack(t, f.source);
  assert.equal(localEntry, entryOf(packaged.staging), "local and packaged installs must not drift");
});


test("publication check rejects a bundle that predates the current panel source", t => {
  const f = sourceFixture(t);
  const { staging, result } = pack(t, f.source);
  assert.equal(result.status, 0, result.stderr);
  for (const file of RUNTIME_FILES) {
    fs.copyFileSync(path.join(f.source, file), path.join(staging, file));
  }
  const current = spawnSync(packager, ["--check", staging], { encoding: "utf8" });
  assert.equal(current.status, 0, current.stderr);
  fs.appendFileSync(path.join(staging, "Panel.qml"), "\n// changed panel source\n");
  const stale = spawnSync(packager, ["--check", staging], { encoding: "utf8" });
  assert.notEqual(stale.status, 0);
  assert.match(stale.stderr, /published runtime is stale/);
});
