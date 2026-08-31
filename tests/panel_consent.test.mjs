import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

function panelFunction(name, context) {
  const expression = new RegExp(`  function ${name}\\(([^)]*)\\) \\{([\\s\\S]*?)\\n  \\}`);
  const match = source.match(expression);
  assert.ok(match, `Panel must expose ${name}`);
  return vm.runInNewContext(`(function(${match[1]}) {${match[2]}\n})`, context);
}

function processExitHandler(id, context) {
  const block = source.split(`    id: ${id}\n`)[1];
  assert.ok(block, `Panel must contain ${id}`);
  const match = block.match(/    onExited: function\(exitCode\) \{([\s\S]*?)\n    \}\n  \}/);
  assert.ok(match, `Process ${id} must handle completion`);
  return vm.runInNewContext(`(function(exitCode) {${match[1]}\n})`, context);
}

// The context is its own `root`, so property writes through either alias stay
// one source of truth, exactly as in the live Panel.
function consentHarness() {
  const context = {
    busy: false,
    helperInstalled: true,
    pendingDeleteName: "",
    pendingReplaceName: "",
    operationKind: "",
    operationName: "",
    operationTimedOut: false,
    recoveryRunning: false,
    statusText: "",
    snapshots: [{ name: "work" }],
    defaultPreset: "",
    operationProcess: { running: false },
    operationOutput: { text: "" },
    operationError: { text: "" },
    operationTimeout: { restart() {}, stop() {} },
    restoreReportPopup: { dismiss() {} },
    Qt: { callLater(fn) { fn(); } },
    snapshotActionsReady() { return !context.busy && context.helperInstalled; },
    helperProcessCommand(args) { return args; },
    normalizeName(value) { return String(value || "").trim().toLowerCase().replace(/\s+/g, "-"); },
    isValidSaveName(value) { return context.normalizeName(value) !== ""; },
    refreshList() { context.refreshes = (context.refreshes || 0) + 1; },
    removeSnapshot() {},
    persistSettings() {},
    operationSummary() { return "summary"; },
    presentRestoreReport() {},
    startTimedOutReplaceRecovery() { context.recoveryStarted = true; },
  };
  context.root = context;
  const harness = {
    context,
    requestReplace: panelFunction("requestReplace", context),
    requestDelete: panelFunction("requestDelete", context),
    runOperation: panelFunction("runOperation", context),
    onExited: processExitHandler("operationProcess", context),
  };
  // The extracted closures call each other through the Panel scope
  // (root.runOperation); expose them on the context the same way.
  context.runOperation = harness.runOperation;
  return harness;
}

test("arming replace captures the target and clears the rival token without launching", t => {
  const h = consentHarness();
  h.context.pendingDeleteName = "work";
  h.requestReplace("work");
  assert.equal(h.context.pendingReplaceName, "work");
  assert.equal(h.context.pendingDeleteName, "");
  assert.equal(h.context.busy, false);
  assert.equal(h.context.operationProcess.running, false);
});

test("arming delete invalidates an armed replace token", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestDelete("work");
  assert.equal(h.context.pendingDeleteName, "work");
  assert.equal(h.context.pendingReplaceName, "");
});

test("a replace that cannot launch yet keeps its token and launches nothing", t => {
  const h = consentHarness();
  h.context.busy = true;
  h.requestReplace("work");
  assert.equal(h.context.pendingReplaceName, "");
  assert.equal(h.context.busy, true);
});

test("accepted replace launch consumes both tokens synchronously", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestReplace("work");
  assert.equal(h.context.pendingReplaceName, "", "consent must not survive the accepted launch");
  assert.equal(h.context.pendingDeleteName, "");
  assert.deepEqual(Array.from(h.context.operationProcess.command), ["replace", "work", "--report-json"]);
  assert.equal(h.context.busy, true);
});

test("accepted delete launch consumes both tokens synchronously", t => {
  const h = consentHarness();
  h.requestDelete("work");
  h.requestDelete("work");
  assert.equal(h.context.pendingDeleteName, "", "consent must not survive the accepted launch");
  assert.equal(h.context.pendingReplaceName, "");
  assert.deepEqual(Array.from(h.context.operationProcess.command), ["delete", "work"]);
});

test("an intervening accepted save clears an armed destructive token", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.runOperation("save", "checkpoint");
  assert.equal(h.context.pendingReplaceName, "", "unrelated accepted input must not leave reusable consent");
  assert.deepEqual(Array.from(h.context.operationProcess.command), ["save", "checkpoint", "--force"]);
});

test("failed intervening input cannot resurrect or inherit destructive consent", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.runOperation("save", "checkpoint");
  h.onExited(1);
  assert.equal(h.context.pendingReplaceName, "", "a failed intervening operation preserves no stale token");
  assert.equal(h.context.operationKind, "", "operation identity is released on failure");
  h.requestReplace("work");
  assert.equal(h.context.pendingReplaceName, "work", "a fresh arm needs a new confirmation click");
  h.requestReplace("work");
  assert.deepEqual(Array.from(h.context.operationProcess.command), ["replace", "work", "--report-json"]);
});

test("nonzero replace leaves no reusable consent and no operation identity", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestReplace("work");
  h.onExited(1);
  assert.equal(h.context.pendingReplaceName, "");
  assert.equal(h.context.pendingDeleteName, "");
  assert.equal(h.context.operationKind, "");
  assert.equal(h.context.operationName, "");
  assert.equal(h.context.busy, false);
});

test("successful replace ends with consumed consent and no operation identity", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestReplace("work");
  h.onExited(0);
  assert.equal(h.context.pendingReplaceName, "");
  assert.equal(h.context.operationKind, "");
  assert.equal(h.context.refreshes >= 1, true);
});

test("operation timeout releases consent and identity without a reusable token", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestReplace("work");
  h.context.operationTimedOut = true;
  h.onExited(1);
  assert.equal(h.context.pendingReplaceName, "");
  assert.equal(h.context.pendingDeleteName, "");
  assert.equal(h.context.operationKind, "");
  assert.equal(h.context.busy, false);
});

test("recovery handoff starts with consent already consumed at launch", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestReplace("work");
  h.context.recoveryRunning = true;
  h.onExited(1);
  assert.equal(h.context.pendingReplaceName, "");
  assert.equal(h.context.pendingDeleteName, "");
  assert.equal(h.context.recoveryStarted, true);
});

test("view reopen cannot turn a consumed token back into armed consent", t => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestReplace("work");
  h.onExited(1);
  // Simulated close/reopen: state is re-read from the same properties.
  const reopened = { pendingReplaceName: h.context.pendingReplaceName, pendingDeleteName: h.context.pendingDeleteName };
  assert.equal(reopened.pendingReplaceName, "");
  assert.equal(reopened.pendingDeleteName, "");
  assert.notEqual(h.context.statusText, "Click Replace again to close current windows.");
});
