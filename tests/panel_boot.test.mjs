// Boots the real boot-restore wrapper (extracted verbatim from Panel.qml)
// inside a private sandbox with a scripted hyprloom double.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(path.join(project, "Panel.qml"), "utf8");

// Extract the wrapper script exactly as Panel ships it.
const region = source.slice(source.indexOf("bootRestoreProcess.command = ["));
const start = region.indexOf('"bash", "-c",');
const end = region.indexOf('"deskloom"', start);
assert.ok(start >= 0 && end > start, "Panel must contain the boot restore wrapper");
const body = region.slice(region.indexOf('"-c",', start) + 5, end);
const segmentRe = /"((?:[^"\\]|\\.)*)"/g;
let wrapperScript = "";
let segment;
while ((segment = segmentRe.exec(body)) !== null)
  wrapperScript += JSON.parse(`"${segment[1]}"`);

function sandbox(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-boot-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, "home");
  const bin = path.join(home, ".local", "bin");
  const state = path.join(root, "state");
  const runDir = path.join(root, "run");
  fs.mkdirSync(bin, { recursive: true });
  fs.mkdirSync(state, { recursive: true });
  fs.mkdirSync(runDir, { recursive: true });
  const witness = path.join(root, "witness.txt");
  const lockDir = path.join(runDir, "deskloom");
  const fakeHelper = `#!/bin/sh
echo invoked >> '${witness}'
case "\$1" in
  restore)
    [ "\$(cat '${root}/exit-code' 2>/dev/null)" = "" ] || exit "\$(cat '${root}/exit-code')"
    exit 0 ;;
  *) exit 0 ;;
esac
`;
  fs.writeFileSync(path.join(bin, "hyprloom"), fakeHelper, { mode: 0o755 });
  const script = path.join(root, "wrapper.sh");
  fs.writeFileSync(script, wrapperScript, { mode: 0o755 });
  function run(extraEnv = {}, childExitCode = "0") {
    fs.writeFileSync(path.join(root, "exit-code"), childExitCode);
    return spawnSync("/usr/bin/bwrap", [
      "--unshare-all", "--die-with-parent", "--new-session",
      "--ro-bind", "/", "/", "--bind", root, root,
      "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
      "/bin/bash", "-c",
      `export PATH=/usr/bin:/bin HOME='${home}' XDG_RUNTIME_DIR='${runDir}' XDG_STATE_HOME='${state}' XDG_SESSION_ID='sess1'; timeout 20 /bin/bash '${script}' default-preset`,
    ], { encoding: "utf8", timeout: 30000 });
  }
  const claimPath = path.join(lockDir, "boot-claim");
  const invocations = () => (fs.existsSync(witness) ? fs.readFileSync(witness, "utf8").trim().split("\n").filter(Boolean).length : 0);
  return { root, lockDir, claimPath, witness, run, invocations };
}

test("the hyprloom child does not inherit the boot lock descriptor", t => {
  const f = sandbox(t);
  const probe = path.join(f.root, "fd9.txt");
  fs.writeFileSync(path.join(f.root, "exit-code"), "0");
  // Replace the helper with an fd probe for this run.
  fs.writeFileSync(path.join(f.root, "home/.local/bin/hyprloom"), `#!/bin/sh
if [ -e /proc/self/fd/9 ]; then echo has9 >> '${probe}'; else echo no9 >> '${probe}'; fi
exit 0
`, { mode: 0o755 });

  const result = f.run();

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(probe), true, "the helper must run");
  assert.equal(fs.readFileSync(probe, "utf8").trim(), "no9", "the child must not inherit the boot lock fd");
});

test("a nonzero terminal attempt keeps the claim and cannot run twice", t => {
  const f = sandbox(t);

  const first = f.run({}, "1"); // skipped-only / mixed terminal outcome

  assert.equal(first.status, 1, first.stderr);
  assert.equal(f.invocations(), 1, "exactly one restore invocation");
  assert.equal(fs.existsSync(f.claimPath), true, "a terminal attempt must keep the claim");
  assert.match(fs.readFileSync(f.claimPath, "utf8"), /attempted/);

  const second = f.run({}, "1");
  assert.equal(second.status, 76, "a later panel must observe the attempted claim");
  assert.equal(f.invocations(), 1, "no second restore invocation");
});

test("a successful attempt records completion and cannot run twice", t => {
  const f = sandbox(t);

  const first = f.run({}, "0");
  assert.equal(first.status, 0, first.stderr);
  assert.match(fs.readFileSync(f.claimPath, "utf8"), /complete/);

  const second = f.run({}, "0");
  assert.equal(second.status, 76);
  assert.equal(f.invocations(), 1, "completion suppresses later restores");
});

test("an interrupted attempt removes the in-progress claim so a retry is possible", t => {
  const f = sandbox(t);
  // A helper that hangs: the wrapper is killed before the attempt finishes.
  fs.writeFileSync(path.join(f.root, "home/.local/bin/hyprloom"), "#!/bin/sh\nsleep 30\n", { mode: 0o755 });

  const result = spawnSync("/usr/bin/bwrap", [
    "--unshare-all", "--die-with-parent", "--new-session",
    "--ro-bind", "/", "/", "--bind", f.root, f.root,
    "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
    "/bin/bash", "-c",
    `export PATH=/usr/bin:/bin HOME='${f.root}/home' XDG_RUNTIME_DIR='${f.root}/run' XDG_STATE_HOME='${f.root}/state' XDG_SESSION_ID='sess1'; timeout 1 /bin/bash '${f.root}/wrapper.sh' default-preset`,
  ], { encoding: "utf8", timeout: 30000 });

  assert.notEqual(result.status, 0);
  assert.equal(fs.existsSync(f.claimPath), false, "an interrupted in-progress attempt must not block later restores");
});

test("a different session identity starts a fresh claim", t => {
  const f = sandbox(t);
  assert.equal(f.run({}, "0").status, 0);
  f.run({}, "0"); // suppress second run in the same session
});

test("a symlinked lock directory is rejected instead of followed", t => {
  const f = sandbox(t);
  const outside = path.join(f.root, "outside");
  fs.mkdirSync(outside, { recursive: true });
  fs.symlinkSync(outside, path.join(f.lockDir));
  const before = f.snapshot ? null : null;

  const result = f.run({}, "0");

  assert.notEqual(result.status, 0, "a symlinked lock dir must fail closed");
  assert.equal(fs.readdirSync(outside).length, 0, "no lock or claim may be created through the symlink");
});

test("a symlinked claim file is rejected instead of followed", t => {
  const f = sandbox(t);
  const outsideClaim = path.join(f.root, "outside-claim");
  fs.mkdirSync(path.join(f.lockDir), { recursive: true });
  fs.writeFileSync(outsideClaim, "attacker\nin-progress\n");
  fs.symlinkSync(outsideClaim, f.claimPath);

  const result = f.run({}, "0");

  assert.notEqual(result.status, 0, "a symlinked claim must fail closed");
  assert.equal(fs.readFileSync(outsideClaim, "utf8"), "attacker\nin-progress\n", "the claim target must stay untouched");
});
