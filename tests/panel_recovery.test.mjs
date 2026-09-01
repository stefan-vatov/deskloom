import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { withBusyStubs } from "./busy_stub.mjs";

const source = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

function processExitHandler(id, context) {
  const block = source.split(`    id: ${id}\n`)[1];
  assert.ok(block, `Panel must contain ${id}`);
  const match = block.match(/    onExited: function\(exitCode\) \{([\s\S]*?)\n    \}\n  \}/);
  assert.ok(match, `Process ${id} must handle completion`);
  return vm.runInNewContext(`(function(exitCode) {${match[1]}\n})`, context);
}

function startupHarness(extra = {}) {
  const context = {

    startupRecoveryTimeout: { stop() {} },
    startupRecoveryErrorText: "",
    busy: false,
    statusText: "",
    refreshPending: false,
    helperInstalled: true,
    Qt: { callLater(fn) { fn(); } },
    root: null,
    ...extra,
  };
  context.root = context;
  withBusyStubs(context);
  return { context, onExited: processExitHandler("startupRecoveryProcess", context) };
}

function recoveryHarness(extra = {}) {
  const context = {

    recoveryTimeout: { stop() {} },
    recoveryRunning: true,
    recoveryErrorText: "",
    busy: true,
    statusText: "",
    pendingDeleteName: "",
    pendingReplaceName: "",
    operationName: "work",
    operationKind: "replace",
    presented: null,
    RestoreReport: { parse() { return { summaryText: "Report unavailable" }; } },
    presentRestoreReport(output, error, exitCode, name, timedOut) {
      context.presented = { output, error, exitCode, name, timedOut };
    },
    refreshList() { context.refreshed = true; },
    root: null,
    ...extra,
  };
  context.root = context;
  withBusyStubs(context);
  return { context, onExited: processExitHandler("recoveryProcess", context) };
}

test("busy ownership cannot be stolen by a second workflow", t => {
  const c = withBusyStubs({ busy: false });
  assert.equal(c.acquireBusy("boot-restore"), true, "an unowned flag may be claimed");
  assert.equal(c.acquireBusy("operation"), false, "a second workflow must not steal the claim");
  assert.equal(c.busyOwner, "boot-restore", "the claim must survive a refused acquisition");
  assert.equal(c.busy, true);
  c.releaseBusy("operation");
  assert.equal(c.busy, true, "a non-owner release must be a no-op");
  assert.equal(c.busyOwner, "boot-restore");
  assert.equal(c.acquireBusy("boot-restore"), true, "the owner may reacquire its own claim");
  c.releaseBusy("boot-restore");
  assert.equal(c.busy, false);
  assert.equal(c.busyOwner, "");
  assert.equal(c.acquireBusy("operation"), true, "after release the flag is claimable again");
});

test("the panel must refuse to hand the busy flag to a second workflow", t => {
  assert.match(source, /function acquireBusy\(owner\) \{[\s\S]*?busyOwner && busyOwner !== owner[\s\S]*?return false/);
});

test("startup recovery failure preserves every stderr line", t => {
  const h = startupHarness({
    startupRecoveryErrorText: "failed transaction: replace-42\nsafety snapshot: autosave-keep\ncmd: hyprloom restore autosave-keep\n",
  });
  h.onExited(1);
  assert.match(h.context.statusText, /failed transaction: replace-42/);
  assert.match(h.context.statusText, /safety snapshot: autosave-keep/);
  assert.match(h.context.statusText, /cmd: hyprloom restore autosave-keep/);
});

test("startup recovery failure keeps a tail without a trailing newline", t => {
  const h = startupHarness({ startupRecoveryErrorText: "line one\nfinal line no newline" });
  h.onExited(1);
  assert.match(h.context.statusText, /line one\nfinal line no newline/);
});

test("startup recovery failure with empty stderr still explains continuation", t => {
  const h = startupHarness({ startupRecoveryError: { text: "" } });
  h.onExited(1);
  assert.match(h.context.statusText, /Startup recovery failed\. Continuing carefully\./);
});

test("startup recovery timeout labels the evidence instead of quoting stderr", t => {
  const h = startupHarness({
    startupRecoveryTimedOut: true,
    startupRecoveryErrorText: "partial bytes\n",
  });
  h.onExited(1);
  assert.match(h.context.statusText, /timed out/);
  assert.equal(h.context.busy, false);
});

test("post-replace recovery failure preserves every stderr line", t => {
  const h = recoveryHarness({
    recoveryErrorText: "desktop recovery incomplete\nmanual step: hyprloom reload\n",
  });
  h.onExited(1);
  assert.match(h.context.statusText, /Desktop recovery failed/);
  assert.match(h.context.statusText, /desktop recovery incomplete\nmanual step: hyprloom reload/);
  assert.equal(h.context.busy, false);
  assert.equal(h.context.recoveryRunning, false);
});

test("post-replace recovery feeds the full diagnostic into the unavailable report", t => {
  const h = recoveryHarness({
    recoveryErrorText: "chunk one\nchunk two without newline",
  });
  h.onExited(1);
  assert.ok(h.context.presented, "recovery must present an unavailable report");
  assert.equal(h.context.presented.output, "");
  assert.equal(h.context.presented.timedOut, true);
  assert.match(h.context.presented.error, /chunk one\nchunk two without newline/);
});

test("successful recovery reports completion and refreshes", t => {
  const h = recoveryHarness({ recoveryError: { text: "" } });
  h.onExited(0);
  assert.match(h.context.statusText, /recovery completed/);
  assert.equal(h.context.refreshed, true);
  assert.equal(h.context.pendingDeleteName, "");
  assert.equal(h.context.pendingReplaceName, "");
  assert.equal(h.context.operationKind, "");
});
