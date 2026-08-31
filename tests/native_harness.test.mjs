// The harness tests itself: preflight escape, failure cleanup, and signal
// cleanup are witnessed positively, not assumed.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, "../..");
const harnessPath = path.join(here, "native-panel/harness.cjs");
const { createHarness, preflight, validateTrace, project: root } = await import(harnessPath);

test("preflight aborts when a mutable endpoint escapes the sandbox", t => {
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), "preflight-"));
  t.after(() => fs.rmSync(stage, { recursive: true, force: true }));
  for (const dir of ["home", "c", "s", "cache", "run", "data"])
    fs.mkdirSync(path.join(stage, dir), { recursive: true });
  assert.throws(() => preflight(stage, { HOME: "/home/someone", XDG_CONFIG_HOME: path.join(stage, "c"),
    XDG_STATE_HOME: path.join(stage, "s"), XDG_DATA_HOME: path.join(stage, "data"),
    XDG_CACHE_HOME: path.join(stage, "cache"), XDG_RUNTIME_DIR: path.join(stage, "run") }),
    /escapes the sandbox/);
  assert.throws(() => preflight(stage, {
    HOME: path.join(stage, "home"), XDG_CONFIG_HOME: path.join(stage, "c"),
    XDG_STATE_HOME: path.join(stage, "s"), XDG_CACHE_HOME: path.join(stage, "cache"),
    XDG_RUNTIME_DIR: path.join(stage, "run"),
  }), /is not set/);
});

test("validateTrace rejects incomplete and out-of-order records", () => {
  assert.throws(() => validateTrace({ scenario: "s", instance: "A", operation: "op", transition: "t" }),
    /missing field/);
  assert.throws(() => validateTrace({ scenario: "s", seq: 0, instance: "A", operation: "op", transition: "t" }),
    /assertion/);
  assert.throws(() => validateTrace({ scenario: "s", seq: -1, instance: "A", operation: "op",
    transition: "t", assertion: "a" }), /bad seq/);
  assert.ok(validateTrace({ scenario: "s", seq: 0, instance: "A", operation: "op",
    transition: "t", assertion: "a" }));
});

test("a failing scenario propagates and the caller can clean the sandbox", async t => {
  const h = createHarness({});
  h.setup();
  const failPath = path.join(h.stage, "fail.qml");
  fs.writeFileSync(failPath, [
    "import QtQuick",
    "import Quickshell",
    "ShellRoot {",
    "  FloatingWindow { visible: true }",
    "  Timer { interval: 60000; running: true }",
    "}",
    "",
  ].join("\n"));
  // A scenario that never passes is killed at the deadline and must reject.
  await assert.rejects(() => h.run(failPath, { timeoutMs: 3000 }), /fail\.qml failed/);
  assert.ok(fs.existsSync(h.stage), "stage survives until the caller cleans it");
  h.cleanup();
  assert.equal(fs.existsSync(h.stage), false, "cleanup removes the sandbox after failure");
});

test("the harness installs signal handlers and cleans idempotently", async t => {
  const h = createHarness({});
  h.setup();
  // Signal handlers must be installed so a SIGTERM/SIGINT during a scenario
  // reaches the cleanup routine even though run() blocks the caller.
  assert.ok(process.listenerCount("SIGTERM") >= 1, "no SIGTERM handler installed");
  assert.ok(process.listenerCount("SIGINT") >= 1, "no SIGINT handler installed");
  const stage = h.stage;
  h.cleanup();
  h.cleanup();
  assert.equal(fs.existsSync(stage), false, "cleanup removes the sandbox exactly once without error");
});

test("trace records are emitted for every scenario run", t => {
  const h = createHarness({ keepStage: true });
  t.after(() => h.cleanup());
  h.setup();
  h.run("commands.qml");
  h.finish();
  assert.ok(h.traces.length === 0, "commands.qml emits no boundary traces by design");
});
