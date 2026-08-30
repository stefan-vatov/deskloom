import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("../", import.meta.url));
const remoteSource = process.env.DESKLOOM_TEST_REMOTE_CARGO === "1";

test(`real Cargo builds the pinned helper from ${remoteSource ? "GitHub" : "a local checkout"} and the native panel accepts it`, {
  skip: process.env.DESKLOOM_TEST_REAL_CARGO !== "1",
}, t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-real-cargo-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, "home");
  const source = path.join(root, "source");
  fs.mkdirSync(home);
  const script = fs.readFileSync(path.join(project, "install-helper.sh"), "utf8");
  const pin = script.match(/readonly expected_source_commit="([^"]+)"/)[1];
  if (!remoteSource) {
    const checkout = process.env.DESKLOOM_HYPRLOOM_SOURCE || path.resolve(project, "../hyprloom");
    for (const args of [["clone", "--quiet", "--no-hardlinks", checkout, source],
      ["-C", source, "checkout", "--quiet", "--detach", pin]]) {
      const result = spawnSync("git", args, { encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
    }
  }
  fs.writeFileSync(path.join(root, "install-helper.sh"), script);
  const command = ["--unshare-all", "--share-net", "--die-with-parent", "--new-session",
    "--ro-bind", "/", "/", "--bind", root, root, "--bind", home, process.env.HOME,
    "--tmpfs", "/run", "--proc", "/proc", "--dev", "/dev",
    "--ro-bind", fs.realpathSync("/etc/resolv.conf"), fs.realpathSync("/etc/resolv.conf"),
    "/bin/bash", path.join(root, "install-helper.sh")];
  const env = { HOME: process.env.HOME, PATH: "/usr/bin:/bin", TMPDIR: root,
    CARGO_HOME: path.join(root, "cargo") };
  if (!remoteSource) env.DESKLOOM_HYPRLOOM_SOURCE = source;
  const result = spawnSync("/usr/bin/bwrap", command, { env, encoding: "utf8", timeout: 300000 });
  process.stdout.write(result.stdout || "");
  process.stderr.write(result.stderr || "");
  assert.equal(result.status, 0, result.error?.message || result.stderr);
  const installed = path.join(home, ".local");
  const binary = path.join(installed, "bin/hyprloom");
  const hash = createHash("sha256").update(fs.readFileSync(binary)).digest("hex");
  assert.equal(fs.readFileSync(path.join(installed, "bin/.hyprloom.sha256"), "utf8"), `${pin} ${hash}\n`);
  assert.equal(fs.existsSync(remoteSource ? source : path.join(source, "target")), false);
  const repeated = spawnSync("/usr/bin/bwrap", command, { env, encoding: "utf8", timeout: 10000 });
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.match(repeated.stdout, /already installed and verified/);
  const native = spawnSync(process.execPath, [path.join(project, "tests/native-panel/run.cjs")], {
    env: { ...process.env, DESKLOOM_TEST_INSTALLED_HELPER: "1", DESKLOOM_TEST_HELPER_ROOT: installed },
    encoding: "utf8", timeout: 60000,
  });
  process.stdout.write(native.stdout || "");
  assert.equal(native.status, 0, native.stderr);
});
