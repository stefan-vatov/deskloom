// Cross-repository executable contract test (beads 081.15 + 081.4).
// Builds the pinned Hyprloom revision and proves Deskloom's machine
// inventory contract end to end: list, compare revisions, conflict,
// refresh, and deliberate retry — never parsing human text.
//
// Opt-in: DESKLOOM_TEST_HYPRLOOM_CONTRACT=1 (requires cargo and the
// ../hyprloom checkout, or DESKLOOM_TEST_HYPRLOOM_SOURCE).
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const skip = process.env.DESKLOOM_TEST_HYPRLOOM_CONTRACT !== "1";

test("pinned hyprloom honors the machine inventory and revision contract", { skip }, t => {
  const source = process.env.DESKLOOM_TEST_HYPRLOOM_SOURCE ?? path.resolve(project, "../hyprloom");
  if (!fs.existsSync(source)) return t.skip("hyprloom checkout not found");
  const installer = fs.readFileSync(path.join(project, "install-helper.sh"), "utf8");
  const pin = installer.match(/readonly expected_source_commit="([^"]+)"/)[1];
  const head = spawnSync("git", ["-C", source, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim();
  const atHead = process.env.DESKLOOM_TEST_HYPRLOOM_HEAD === "1";
  if (!atHead && head !== pin)
    return t.skip(`hyprloom HEAD ${head.slice(0, 8)} differs from pin ${pin.slice(0, 8)}; run after pushing/rebasing`);


  // Build the pinned revision (cargo locks the target dir, so concurrent
  // sessions serialize safely).
  const build = spawnSync("cargo", ["build", "--quiet"], { cwd: source, encoding: "utf8", timeout: 600000 });
  assert.equal(build.status, 0, build.stderr?.slice(-2000));
  const binary = path.join(source, "target", "debug", "hyprloom");

  // Isolated storage: a private HOME whose hyprloom sessions dir we seed.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), String(process.getuid?.() ?? 1000) + "/contract-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const data = path.join(root, "data");
  const sessions = path.join(data, "hyprloom", "sessions");
  fs.mkdirSync(sessions, { recursive: true, mode: 0o700 });
  const session = { name: "work", created_at: "2026-01-01T00:00:00Z", hyprland_version: "contract",
    monitors: [], clients: [] };
  fs.writeFileSync(path.join(sessions, "work.json"), JSON.stringify(session), { mode: 0o600 });

  const logs = [`build target: ${atHead ? "HEAD" : "pin"} ${head.slice(0, 8)}`];
  function run(args) {
    const result = spawnSync(binary, args, {
      env: { HOME: path.join(root, "home"), XDG_DATA_HOME: data, PATH: "/usr/bin:/bin", HYPRLOOM_SESSIONS_DIR: sessions },
      encoding: "utf8", timeout: 30000,
    });
    logs.push(`hyprloom ${args.join(" ")} -> ${result.status}`);
    return result;
  }
  function inventory() {
    const result = run(["list", "--json"]);
    assert.equal(result.status, 0, result.stderr);
    const doc = JSON.parse(result.stdout);
    assert.equal(doc.schema_version, 1);
    assert.equal(doc.protocol, "deskloom.inventory");
    assert.ok(Array.isArray(doc.sessions));
    return doc.sessions;
  }
  function conflict(result, expected) {
    assert.equal(result.status, 3, "a revision conflict exits 3");
    const doc = JSON.parse(result.stdout);
    assert.equal(doc.error, "revision-conflict");
    assert.equal(doc.expected, expected);
    assert.ok(doc.actual === null || typeof doc.actual === "string");
    return doc;
  }

  // 1. Refresh: the inventory lists the seeded session with a stable revision.
  const first = inventory();
  assert.equal(first.length, 1);
  assert.equal(first[0].name, "work");
  assert.match(first[0].revision, /^[a-f0-9]{16}$/);
  const revisionOne = first[0].revision;
  assert.equal(inventory()[0].revision, revisionOne, "revisions are stable for unchanged bytes");

  // 2. One byte changes -> the revision must change.
  fs.appendFileSync(path.join(sessions, "work.json"), "\n");
  const second = inventory()[0].revision;
  assert.notEqual(second, revisionOne, "a dependency byte change must move the revision");

  // 3. Conflict: a delete expecting the stale revision mutates nothing.
  const bytes = fs.readFileSync(path.join(sessions, "work.json"));
  const stale = run(["delete", "work", "--if-revision", revisionOne]);
  conflict(stale, revisionOne);
  assert.deepEqual(fs.readFileSync(path.join(sessions, "work.json")), bytes, "no mutation on conflict");

  // 4. Deliberate retry with the fresh revision succeeds.
  const retry = run(["delete", "work", "--if-revision", second]);
  assert.equal(retry.status, 0, retry.stderr);
  assert.equal(fs.existsSync(path.join(sessions, "work.json")), false);

  // 5. Human list output remains available beside the machine form.
  const human = run(["list"]);
  assert.equal(human.stdout.includes("deskloom.inventory"), false, "human list must stay human");
  assert.ok(human.stdout.trim().length > 0 || human.stderr.trim().length > 0, "human list still produces output");

  process.stdout.write("CONTRACT_LOG\n" + logs.map(l => "  " + l).join("\n") + "\n");
});
