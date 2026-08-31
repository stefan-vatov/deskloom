import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { withBusyStubs } from "./busy_stub.mjs";

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
// one source of truth, exactly as in the live Panel. withBusyStubs attaches
// the ownership helpers the extracted handlers call.
function consentHarness() {
  const context = withBusyStubs({
    busy: false,
    helperInstalled: true,
    consentGeneration: 0,
    consentLog: [],
    pendingDeleteName: "",
    pendingReplaceName: "",
    pendingReplaceRevision: "",
    pendingDeleteRevision: "",
    pendingSaveName: "",
    pendingSaveRevision: "",
    operationKind: "",
    operationName: "",
    operationTimedOut: false,
    recoveryRunning: false,
    statusText: "",
    snapshots: [
      { name: "work", windows: 3, created: "c", automatic: false, revision: "aaaa1111aaaa1111" },
      { name: "play", windows: 1, created: "c", automatic: false, revision: "bbbb2222bbbb2222" },
    ],
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
    revisionOf(name) {
      const row = context.snapshots.find(s => s.name === name);
      return row ? row.revision : "";
    },
    operationSummary() { return "summary"; },
    presentRestoreReport() {},
    startTimedOutReplaceRecovery() { context.recoveryStarted = true; },
  });
  context.logConsent = transition => {
    context.consentGeneration += 1;
    context.consentLog.push("consent generation " + context.consentGeneration + ": " + transition);
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
  assert.deepEqual(Array.from(h.context.operationProcess.command),
    ["replace", "work", "--report-json", "--if-revision", "aaaa1111aaaa1111"]);
  assert.equal(h.context.busy, true);
});

test("accepted delete launch consumes both tokens synchronously", t => {
  const h = consentHarness();
  h.requestDelete("work");
  h.requestDelete("work");
  assert.equal(h.context.pendingDeleteName, "", "consent must not survive the accepted launch");
  assert.equal(h.context.pendingReplaceName, "");
  assert.deepEqual(Array.from(h.context.operationProcess.command),
    ["delete", "work", "--if-revision", "aaaa1111aaaa1111"]);
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
  assert.deepEqual(Array.from(h.context.operationProcess.command),
    ["replace", "work", "--report-json", "--if-revision", "aaaa1111aaaa1111"]);
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
  const reopened = { pendingReplaceName: h.context.pendingReplaceName, pendingDeleteName: h.context.pendingDeleteName };
  assert.equal(reopened.pendingReplaceName, "");
  assert.equal(reopened.pendingDeleteName, "");
  assert.notEqual(h.context.statusText, "Click Replace again to close current windows.");
});

test("consent transitions are logged as sanitized generations without snapshot names", () => {
  const h = consentHarness();
  h.requestReplace("work");
  h.requestDelete("work");
  h.requestReplace("work");
  h.requestReplace("work"); // confirming click: consumes at the launch boundary
  h.onExited(1);
  assert.deepEqual(h.context.consentLog, [
    "consent generation 1: armed-replace",
    "consent generation 2: armed-delete",
    "consent generation 3: armed-replace",
    "consent generation 4: consumed-replace",
  ]);
  for (const line of h.context.consentLog)
    assert.doesNotMatch(line, /work/, "consent logs must not record snapshot names");
});

test("arming destructive consent captures the confirmed snapshot revision", () => {
  const h = consentHarness();
  h.requestReplace("work");
  assert.equal(h.context.pendingReplaceRevision, "aaaa1111aaaa1111",
    "the arm must bind to the revision the user saw");
  h.requestReplace("work");
  assert.deepEqual(Array.from(h.context.operationProcess.command).slice(-2),
    ["--if-revision", "aaaa1111aaaa1111"], "the confirmed revision must guard the mutation");
});

test("a list refresh that changes a target's revision invalidates the armed consent", () => {
  const h = consentHarness();
  h.requestReplace("work");
  h.context.snapshots = [
    { name: "work", windows: 9, created: "c", automatic: false, revision: "cccc3333cccc3333" },
  ];
  h.runOperation("replace", "work");
  assert.equal(h.context.pendingReplaceName, "", "stale consent must be invalidated by the refresh");
  assert.equal(h.context.operationProcess.command, undefined, "a stale arm must not launch");
});

test("delete consent binds to the revision and guards the delete", () => {
  const h = consentHarness();
  h.requestDelete("play");
  assert.equal(h.context.pendingDeleteRevision, "bbbb2222bbbb2222");
  h.requestDelete("play");
  assert.deepEqual(Array.from(h.context.operationProcess.command).slice(-2),
    ["--if-revision", "bbbb2222bbbb2222"]);
});

test("a hidden normalized-name collision requires an explicit second confirmation", () => {
  const h = consentHarness();
  h.context.snapshots = [
    { name: "tax-2025", windows: 4, created: "c", automatic: false, revision: "dddd4444dddd4444" },
  ];
  // "Tax 2025" normalizes onto the existing tax-2025 snapshot.
  h.runOperation("save", "Tax 2025");
  assert.equal(h.context.pendingSaveName, "Tax 2025", "the collision must arm a pending overwrite");
  assert.equal(h.context.busy, false, "no overwrite may run from a single click");
  assert.equal(h.context.operationProcess.command, undefined, "no mutation before the second confirmation");

  h.runOperation("save", "Tax 2025");
  assert.deepEqual(Array.from(h.context.operationProcess.command),
    ["save", "tax-2025", "--force", "--if-revision", "dddd4444dddd4444"],
    "the informed second click overwrites with a revision guard");
  assert.equal(h.context.pendingSaveName, "", "the one-use confirmation is consumed");
});

test("an exact-name save overwrite keeps its single-click flow", () => {
  const h = consentHarness();
  h.context.snapshots = [{ name: "work", windows: 2, created: "c", automatic: false, revision: "eeee5555eeee5555" }];
  h.runOperation("save", "work");
  assert.deepEqual(Array.from(h.context.operationProcess.command).slice(0, 2), ["save", "work"],
    "a deliberate same-name update needs no collision arm");
  assert.equal(h.context.busy, true);
});

test("a collision with a nonexistent snapshot saves directly", () => {
  const h = consentHarness();
  h.runOperation("save", "fresh-name");
  assert.deepEqual(Array.from(h.context.operationProcess.command).slice(0, 2), ["save", "fresh-name"]);
  assert.equal(h.context.busy, true);
});
