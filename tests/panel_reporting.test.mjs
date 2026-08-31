import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

test("helper setup is an explicit Cargo build with matching release metadata", () => {
  const installer = fs.readFileSync(new URL("../install-helper.sh", import.meta.url), "utf8");
  const pin = installer.match(/readonly expected_source_commit="([^"]+)"/)[1];
  const version = installer.match(/readonly expected_version="([^"]+)"/)[1];
  assert.ok(source.includes(`helperSourceCommit: "${pin}"`));
  assert.ok(source.includes(`helperVersion: "${version}"`));
  assert.match(source, /Build and install Hyprloom/);
  assert.match(source, /omarchy-launch-floating-terminal-with-presentation/);
  assert.doesNotMatch(source, /AUR|aur-install|pacman/);
  assert.equal((source.match(/helper-install\.lock/g) || []).length, 2);
  assert.equal((source.match(/helper-install-result-\$1/g) || []).length, 2);
});

test("report diagnostics in the panel status remain plain text", () => {
  const status = source.match(/TextEdit \{[^{}]*text: root\.statusText[^{}]*\}/);
  assert.ok(status);
  assert.match(status[0], /textFormat: TextEdit\.PlainText/);
});

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

function operationHarness() {
  const context = {
    busy: false,
    helperInstalled: true,
    operationProcess: {},
    operationTimeout: { restart() {} },
    restoreReportPopup: { dismiss() {} },
    root: { helperProcessCommand: args => args },
  };
  return { context, run: panelFunction("runOperation", context) };
}

test("read-only reporting diagnostics identify the loaded component and retained result", () => {
  const context = {
    root: { pluginVersion: "fixture", helperVersion: "helper", helperSourceCommit: "source", reportScreenName: "DP-1", helperInstalled: true, busy: false,
      snapshots: [{}], snapshotsLoaded: true, snapshotListFailed: false },
    Qt: { resolvedUrl: () => "file:///runtime/revision/Panel.qml" },
    restoreReportPopup: { open: false, report: { available: true, counts: { unchanged: 1, launched: 1 } } },
  };
  const value = JSON.parse(panelFunction("reportingStatus", context)());
  assert.equal(value.version, "fixture");
  assert.equal(value.helperVersion, "helper");
  assert.equal(value.snapshotCount, 1);
  assert.equal(value.componentUrl, "file:///runtime/revision/Panel.qml");
  assert.equal(value.monitor, "DP-1");
  assert.equal(value.hasReport, true);
  assert.equal(value.reportOpen, false);
  assert.deepEqual(value.counts, { unchanged: 1, launched: 1 });
  assert.equal(Object.hasOwn(value, "windows"), false);
});

test("operation failures keep the complete diagnostic while success stays concise", () => {
  const summary = panelFunction("operationSummary", {
    operationOutput: { text: "Saved snapshot\nExtra detail" },
    operationError: { text: "error: invalid command\nUsage: hyprloom COMMAND\nlast line" },
  });
  assert.equal(summary(true), "error: invalid command\nUsage: hyprloom COMMAND\nlast line");
  assert.equal(summary(false), "Saved snapshot");
});

test("a failed or pending listing does not claim saved snapshots are gone", () => {
  const root = { snapshots: [], snapshotsLoaded: false, snapshotListFailed: false };
  const message = panelFunction("emptySnapshotMessage", { root });
  assert.equal(message(), "Loading snapshots…");
  root.snapshotListFailed = true;
  assert.equal(message(), "Could not load snapshots. Try Refresh snapshots.");
  root.snapshotListFailed = false;
  root.snapshotsLoaded = true;
  assert.match(message(), /^No snapshots yet/);
  root.snapshots = [{}];
  assert.equal(message(), "");
});

test("Open requests structured reconciliation results", () => {
  const { context, run } = operationHarness();
  run("restore", "coding");
  assert.deepEqual(Array.from(context.operationProcess.command), ["restore", "coding", "--reconcile", "--report-json"]);
});

test("Replace requests structured results without bypassing the guarded command", () => {
  const { context, run } = operationHarness();
  run("replace", "coding");
  assert.deepEqual(Array.from(context.operationProcess.command), ["replace", "coding", "--report-json"]);
});

test("completed report is presented and the ordinary panel relinquishes its popup", () => {
  const events = [];
  const result = { available: true, summaryText: "1 found existing" };
  const context = {
    RestoreReport: { parse: (...args) => { events.push(["parse", ...args]); return result; } },
    root: { close: () => events.push(["close"]), statusText: "" },
    restoreReportPopup: { present: report => events.push(["present", report]) },
  };
  const present = panelFunction("presentRestoreReport", context);
  present("{}", "", 0, "coding", false);
  assert.equal(events[0][0], "parse");
  assert.equal(events[1][0], "close");
  assert.deepEqual(events[2], ["present", result]);
  assert.equal(context.root.statusText, "1 found existing");
});

test("timeout cannot present a completed-looking payload as success", () => {
  let observed;
  const context = {
    RestoreReport: { parse: (...args) => { observed = args; return { summaryText: "Report unavailable" }; } },
    root: { close() {}, statusText: "" },
    restoreReportPopup: { present() {} },
  };
  panelFunction("presentRestoreReport", context)("{\"report\":{}}", "Operation timed out", 0, "coding", true);
  assert.equal(observed[0], "");
  assert.equal(observed[1], 1);
  assert.match(observed[2], /timed out/i);
});

test("only the login instance that restored shows a result", () => {
  for (const exitCode of [0, 75, 76]) {
    const shown = [];
    const context = {
      root: { bootRestoreTimedOut: false, bootRestoreRetries: 3, bootRestorePreset: "coding",
        presentRestoreReport: (...args) => shown.push(args), refreshList() {} },
      bootRestoreTimeout: { stop() {} }, bootRestoreOutput: { text: "{}" }, bootRestoreError: { text: "" },
    };
    processExitHandler("bootRestoreProcess", context)(exitCode);
    assert.equal(shown.length, exitCode === 0 ? 1 : 0);
    if (exitCode === 75) {
      assert.equal(context.root.busy, false);
      assert.equal(context.root.statusText, "Automatic restore skipped: startup lock was busy.");
    }
  }
});

test("login safe skips use structured outcomes and do not retry", () => {
  const shown = [];
  let refreshed = false;
  const context = {
    root: { bootRestoreTimedOut: false, bootRestoreRetries: 0, bootRestorePreset: "coding",
      presentRestoreReport: (...args) => shown.push(args), refreshList: () => { refreshed = true; } },
    RestoreReport: { parse: () => ({ available: true, counts: { skipped: 1, failed: 0 } }) },
    bootRestoreTimeout: { stop() {} }, bootRestoreOutput: { text: "{}" }, bootRestoreError: { text: "" },
  };
  processExitHandler("bootRestoreProcess", context)(1);
  assert.equal(shown.length, 1);
  assert.equal(context.root.bootRestoreRetries, 0);
  assert.equal(refreshed, true);
});

test("manual completion reports restores, not saves or deletes", () => {
  for (const kind of ["restore", "replace", "save", "delete"]) {
    const shown = [];
    const context = {
      root: { operationKind: kind, operationName: "coding", defaultPreset: "other",
        recoveryRunning: false, operationTimedOut: false,
        presentRestoreReport: (...args) => shown.push(args), refreshList() {}, removeSnapshot() {},
        operationSummary: () => "Done" },
      operationTimeout: { stop() {} }, operationOutput: { text: "{}" }, operationError: { text: "" },
    };
    processExitHandler("operationProcess", context)(0);
    assert.equal(shown.length, kind === "restore" || kind === "replace" ? 1 : 0);
    assert.equal(context.root.operationKind, "");
  }
});

test("helper readiness proves provenance before executing the candidate", () => {
  const ready = source.match(/function helperReadyCheck\(\) \{([\s\S]*?)\n  \}/);
  assert.ok(ready, "Panel must expose helperReadyCheck");
  const body = ready[1];
  const markerAt = body.indexOf(".hyprloom.sha256");
  const digestAt = body.indexOf("sha256sum");
  const versionAt = body.indexOf("--version");
  const helpAt = body.indexOf("--help");
  assert.ok(markerAt >= 0 && digestAt > markerAt, "marker must be checked before the digest");
  assert.ok(digestAt >= 0 && versionAt > digestAt, "the candidate may execute only after its digest verifies");
  assert.ok(helpAt > versionAt);
});
