import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("../", import.meta.url));
const script = fs.readFileSync(path.join(project, "install-helper.sh"), "utf8");
const pin = script.match(/readonly expected_source_commit="([^"]+)"/)[1];
const version = script.match(/readonly expected_version="([^"]+)"/)[1];
const repository = "https://github.com/stefan-vatov/hyprloom.git";

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-cargo-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  fs.mkdirSync(home);
  fs.mkdirSync(bin);
  fs.copyFileSync(path.join(project, "install-helper.sh"), path.join(root, "install-helper.sh"));
  const binary = path.join(home, ".local/bin/hyprloom");
  const marker = path.join(home, ".local/bin/.hyprloom.sha256");
  const calls = path.join(root, "cargo.jsonl");
  const denied = path.join(root, "forbidden");
  for (const command of ["omarchy-pkg-aur-add", "yay", "pacman", "sudo"])
    fs.writeFileSync(path.join(bin, command), `#!/bin/sh\necho ${command} >> '${denied}'\nexit 1\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "cargo"), `#!${process.execPath}
const fs = require('node:fs'), path = require('node:path');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.TEST_CARGO_CALLS, JSON.stringify(args) + '\\n');
if (process.env.TEST_BUILD_FAIL === '1') process.exit(101);
if (args[0] !== 'install') process.exit(2);
const root = args[args.indexOf('--root') + 1];
fs.mkdirSync(path.join(root, 'bin'), {recursive:true});
fs.writeFileSync(path.join(root, 'bin/hyprloom'), '#!/bin/sh\\ncase "$1" in\\n--version) echo "hyprloom ' + (process.env.TEST_BAD_VERSION === '1' ? '0.0.0' : process.env.TEST_VERSION) + '";;\\n--help) exit 0;;\\n*) exit 2;;\\nesac\\n', {mode:0o755});
if (process.env.TEST_DIRTY_DURING_BUILD === '1') fs.appendFileSync(args[args.indexOf('--path') + 1] + '/Cargo.toml', '\\n# changed during build\\n');
`, { mode: 0o755 });
  function seedInstalled(valid = false) {
    fs.mkdirSync(path.dirname(binary), { recursive: true });
    fs.writeFileSync(binary, `#!/bin/sh\ncase "$1" in --version) echo 'hyprloom ${valid ? version : "0.0.0"}';; --help) exit 0;; *) exit 2;; esac\n`, { mode: 0o755 });
    fs.writeFileSync(marker, `${pin} ${createHash("sha256").update(fs.readFileSync(binary)).digest("hex")}\n`);
  }
  function run(extra = {}) {
    // Keep HOME unchanged; isolate its filesystem in a private, offline namespace.
    return spawnSync("/usr/bin/bwrap", ["--unshare-all", "--die-with-parent", "--new-session",
      "--ro-bind", "/", "/", "--bind", root, root, "--bind", home, process.env.HOME,
      "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
      "/bin/bash", path.join(root, "install-helper.sh")], {
      env: { HOME: process.env.HOME, PATH: `${bin}:/usr/bin:/bin`, TMPDIR: root,
        TEST_CARGO_CALLS: calls, TEST_VERSION: version, ...extra }, encoding: "utf8", timeout: 15000,
    });
  }
  function localCheckout() {
    const source = path.join(root, "source");
    fs.mkdirSync(source);
    fs.writeFileSync(path.join(source, "Cargo.toml"), '[package]\nname = "hyprloom"\nversion = "' + version + '"\n');
    fs.writeFileSync(path.join(source, "Cargo.lock"), "version = 4\n");
    for (const args of [["init", "--quiet"], ["add", "."],
      ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"]]) {
      const result = spawnSync("git", args, { cwd: source, encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
    }
    const revision = spawnSync("git", ["rev-parse", "HEAD"], { cwd: source, encoding: "utf8" }).stdout.trim();
    // Change only release metadata; execute the production installer unchanged.
    fs.writeFileSync(path.join(root, "install-helper.sh"), script.replace(pin, revision));
    return source;
  }
  return { root, bin, binary, marker, calls, denied, seedInstalled, run, localCheckout };
}

test("uses pinned Cargo Git installation without package managers", t => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(f.denied), false);
  const calls = fs.readFileSync(f.calls, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(calls.length, 1);
  const args = calls[0];
  assert.equal(args[0], "install");
  assert.equal(args[args.indexOf("--git") + 1], repository);
  assert.equal(args[args.indexOf("--rev") + 1], pin);
  assert.equal(args[args.indexOf("--bin") + 1], "hyprloom");
  assert.ok(args.includes("--locked"));
  assert.ok(args[args.indexOf("--root") + 1].startsWith(f.root + "/"));
  assert.ok(args[args.indexOf("--target-dir") + 1].startsWith(f.root + "/"));
  const hash = createHash("sha256").update(fs.readFileSync(f.binary)).digest("hex");
  assert.equal(fs.readFileSync(f.marker, "utf8"), `${pin} ${hash}\n`);
  assert.equal(f.run().status, 0);
  assert.equal(fs.readFileSync(f.calls, "utf8").trim().split("\n").length, 1);
});

test("a verified existing install needs no build or download", t => {
  const f = fixture(t);
  f.seedInstalled(true);
  assert.equal(f.run().status, 0);
  assert.equal(fs.existsSync(f.calls), false);
  assert.equal(fs.existsSync(f.denied), false);
});

for (const flag of ["TEST_BUILD_FAIL", "TEST_BAD_VERSION"]) {
  test(`${flag} preserves the previous helper and marker`, t => {
    const f = fixture(t);
    f.seedInstalled();
    const binary = fs.readFileSync(f.binary);
    const marker = fs.readFileSync(f.marker);
    const result = f.run({ [flag]: "1" });
    assert.notEqual(result.status, 0);
    assert.deepEqual(fs.readFileSync(f.binary), binary);
    assert.deepEqual(fs.readFileSync(f.marker), marker);
    assert.equal(fs.existsSync(f.denied), false);
  });
}

test("an explicitly selected invalid checkout fails without a remote fallback", t => {
  const f = fixture(t);
  const result = f.run({ DESKLOOM_HYPRLOOM_SOURCE: path.join(f.root, "missing") });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /clean checkout.*pinned revision/i);
  assert.equal(fs.existsSync(f.calls), false);
});

test("a clean explicit checkout uses Cargo path mode and leaves its target alone", t => {
  const f = fixture(t);
  const source = f.localCheckout();
  const result = f.run({ DESKLOOM_HYPRLOOM_SOURCE: source });
  assert.equal(result.status, 0, result.stderr);
  const args = JSON.parse(fs.readFileSync(f.calls, "utf8").trim());
  assert.equal(args[args.indexOf("--path") + 1], source);
  assert.equal(args.includes("--git"), false);
  assert.equal(fs.existsSync(path.join(source, "target")), false);
});

test("a dirty explicit checkout is rejected before Cargo runs", t => {
  const f = fixture(t);
  const source = f.localCheckout();
  fs.appendFileSync(path.join(source, "Cargo.toml"), "\n# dirty\n");
  assert.notEqual(f.run({ DESKLOOM_HYPRLOOM_SOURCE: source }).status, 0);
  assert.equal(fs.existsSync(f.calls), false);
});

test("a checkout changed during compilation is not installed", t => {
  const f = fixture(t);
  const source = f.localCheckout();
  f.seedInstalled();
  const before = fs.readFileSync(f.binary);
  const result = f.run({ DESKLOOM_HYPRLOOM_SOURCE: source, TEST_DIRTY_DURING_BUILD: "1" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /checkout changed during the build/);
  assert.deepEqual(fs.readFileSync(f.binary), before);
});

test("missing build prerequisites are explained without installing packages", t => {
  const f = fixture(t);
  const result = f.run({ PATH: f.bin });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /rustc is required/);
  assert.equal(fs.existsSync(f.calls), false);
  assert.equal(fs.existsSync(f.denied), false);
});

test("symlinked destination directories are rejected before building", t => {
  const f = fixture(t);
  const outside = path.join(f.root, "outside");
  fs.mkdirSync(outside);
  fs.symlinkSync(outside, path.join(f.root, "home/.local"));
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /symlink/i);
  assert.equal(fs.existsSync(f.calls), false);
  assert.deepEqual(fs.readdirSync(outside), []);
});
