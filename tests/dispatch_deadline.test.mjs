// Dispatch-gated deadlines (bead vq4): execution deadlines arm only when the
// pinned helper authoritatively reports "dispatch: started" on stderr — queue
// time behind another operation is never charged as a hang.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

function noteHarness(channel) {
  const restarted = [];
  const context = {
    listDispatched: false, operationDispatched: false, bootDispatched: false,
    startupDispatched: false, recoveryDispatched: false,
    listErrorText: "", operationErrorText: "", bootRestoreErrorText: "",
    startupRecoveryErrorText: "", recoveryErrorText: "",
    listTimeout: { restart: () => restarted.push("list") },
    operationTimeout: { restart: () => restarted.push("operation") },
    bootRestoreTimeout: { restart: () => restarted.push("boot") },
    startupRecoveryTimeout: { restart: () => restarted.push("startup") },
    recoveryTimeout: { restart: () => restarted.push("recovery") },
  };
  return { context, restarted, note: vm.runInNewContext(
    `(function(channel, line) {${source.match(/  function noteHelperLine\(channel, line\) \{([\s\S]*?)\n  \}/)[1]}\n})`, context) };
}

test("the dispatch marker arms only the caller's execution deadline", () => {
  const h = noteHarness("list");
  h.note("list", "dispatch: started list default");
  assert.equal(h.context.listDispatched, true);
  assert.deepEqual(h.restarted, ["list"]);
  h.note("list", "dispatch: started replace other");
  assert.equal(h.context.listDispatched, true);
  assert.deepEqual(h.restarted, ["list", "list"], "the marker arms the deadline, not other channels");
});

test("non-dispatch stderr accumulates into the error surface without arming", () => {
  const h = noteHarness("operation");
  h.note("operation", "queued behind another operation");
  h.note("operation", "second line");
  assert.equal(h.context.operationDispatched, false, "plain stderr must not arm the deadline");
  assert.deepEqual(h.restarted, []);
  assert.equal(h.context.operationErrorText, "queued behind another operation\nsecond line\n");
  h.note("operation", "dispatch: started replace work");
  assert.equal(h.context.operationDispatched, true);
  assert.equal(h.context.operationErrorText.includes("queued"), true, "accumulated diagnostics are kept");
});

test("each workflow arms its own deadline exactly once per dispatch", () => {
  for (const channel of ["list", "operation", "boot", "startup", "recovery"]) {
    const h = noteHarness(channel);
    h.note(channel, "dispatch: started " + channel + " work");
    assert.equal(h.restarted.length, 1, channel + " arms its own deadline");
    assert.equal(h.context[channel + "Dispatched"], true);
  }
});

test("empty lines never arm or accumulate", () => {
  const h = noteHarness("boot");
  h.note("boot", "");
  assert.deepEqual(h.restarted, []);
  assert.equal(h.context.bootRestoreErrorText, "");
});
