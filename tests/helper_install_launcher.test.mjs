// Helper-install launcher ordering: bead deskloom-production-defect-audit-081.5.
//
// AUDIT — every observation in the launcher region with its current ordering:
//
// Writer (detached bash built inside openHelperInstaller, one command string):
//   W0 umask 077; lock_root/lock_dir created with symlink/ownership checks
//   W1 lock acquisition:      exec 9>"$lock_dir/helper-install.lock"; flock -n 9 || exit 75
//   W2 stale-result removal:  helper-install-result-$1 symlink/regular check, then rm -f
//                             — runs under the lock, after W1
//   W3 installer execution:   "$installer" run; verdict classified success/failure
//   W4 result publication:    mktemp in lock_dir → printf verdict → chmod 600
//                             → mv -f onto result_file (atomic rename) → exit code
//   Publication is attempt-scoped (result file name carries $1 = attempt id),
//   locked, and atomic; W1 < W2 < W3 < W4 within the command string.
//
// Reader (QML, Panel.qml):
//   R0 openHelperInstaller resets attempt state (attempt id = Date.now())
//   R1 Quickshell.execDetached(launch) — the writer starts; unordered vs readers
//   R2 installPoll.start() / installTimeout.start() — after R1 in statement
//      order, but nothing enforces it
//   R3 installPoll tick:      checkHelper() → checkInstallerResult() (result read)
//                             → checkInstallerLock() once polls >= 5
//   R4 installerResultProbe exit: verdict read → success/failure transitions
//   R5 installerLockProbe exit:   "free" → "installer stopped" transition
//   R6 installTimeout:            timed-out transition, then a lock probe
//
// Gaps fixed by this change:
//   G1 the readiness machinery only checked `installingHelper`; a result probe
//      started before launch, or one left over from a superseded attempt,
//      could deliver a stale verdict into the live attempt (R1/R3/R4 race)
//   G2 result-read and lock-read had no launch gate: their ordering against
//      execDetached was incidental, not enforced (R1 vs R3/R5/R6)
//   G3 launcher decisions (launch, guards, verdicts, lock state, timeouts,
//      statusText transitions) carried no console diagnostics (all of R3–R6)
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

// Probe processes close with a parameterless onExited handler.
function probeExitHandler(id, context) {
  const block = source.split(`    id: ${id}\n`)[1];
  assert.ok(block, `Panel must contain ${id}`);
  const match = block.match(/    onExited: function\(\) \{([\s\S]*?)\n    \}\n  \}/);
  assert.ok(match, `Process ${id} must handle completion`);
  return vm.runInNewContext(`(function() {${match[1]}\n})`, context);
}

// Timers (installPoll, installTimeout) expose onTriggered bodies.
function timerHandler(id, context) {
  const block = source.split(`    id: ${id}\n`)[1];
  assert.ok(block, `Panel must contain ${id}`);
  const match = block.match(/    onTriggered: \{([\s\S]*?)\n    \}\n  \}/);
  assert.ok(match, `Timer ${id} must handle ticks`);
  return vm.runInNewContext(`(function() {${match[1]}\n})`, context);
}

function logger() {
  const lines = [];
  const api = {
    lines,
    console: { log: (...args) => lines.push(args.join(" ")) },
    busyOwner: "",
    acquireBusy: o => { api.busy = true; },
    releaseBusy: o => { api.busy = false; },
  };
  return api;
}

function launchHarness({ busy = false, helperInstalled = false } = {}) {
  const events = [];
  const log = logger();
  const context = withBusyStubs({
    busy, helperInstalled,
    installerTimedOut: false,
    installerFinished: false,
    installerAttemptId: "",
    installerPolls: 0,
    installingHelper: false,
    statusText: "",
    ...log,
    Date,
    Quickshell: { execDetached: argv => { events.push("exec-detached"); return argv; } },
    installPoll: { start: () => events.push("poll-start") },
    installTimeout: { start: () => events.push("timeout-start") },
  });
  Object.defineProperty(context, "installerLaunched", {
    get() { return this._launched === true; },
    set(value) { events.push(value ? "launched" : "launch-cleared"); this._launched = value === true; },
  });
  return { context, events, lines: log.lines, run: panelFunction("openHelperInstaller", context) };
}

test("writer orders lock acquisition, stale-result removal, installer run, and atomic publication", () => {
  const script = writerScript();
  const lock = script.indexOf('flock -n 9 || exit 75');
  const clear = script.indexOf('rm -f "$result_file"');
  const install = script.indexOf('"$installer"; then');
  const stage = script.indexOf("temporary=$(mktemp");
  const publish = script.indexOf('mv -f "$temporary" "$result_file"');
  for (const [name, at] of [["lock", lock], ["clear", clear], ["install", install], ["stage", stage], ["publish", publish]])
    assert.ok(at >= 0, `writer must contain ${name}`);
  assert.ok(lock < clear, "the lock must be held before any result file is touched");
  assert.ok(clear < install, "a stale result must be removed before the installer runs");
  assert.ok(install < stage, "the verdict must be staged only after the installer finishes");
  assert.ok(stage < publish, "publication must be an atomic rename of the staged verdict");
  assert.ok(script.includes("helper-install-result-$1"), "the result file must be attempt-scoped");
});

function writerScript() {
  const start = source.indexOf("var installCommand = ");
  const end = source.indexOf("Quickshell.execDetached", start);
  assert.ok(start >= 0 && end > start, "Panel must build installCommand before launch");
  const segmentRe = /"((?:[^"\\]|\\.)*)"/g;
  let script = "";
  let segment;
  while ((segment = segmentRe.exec(source.slice(start, end))) !== null)
    script += JSON.parse(`"${segment[1]}"`);
  return script;
}

test("the result reader only cats an attempt-scoped regular file", () => {
  const block = source.split("  function checkInstallerResult(")[1];
  assert.ok(block.includes("helper-install-result-$1"), "reader must target the attempt-scoped result");
  const guard = block.indexOf("[ -L ");
  const read = block.indexOf("cat ");
  assert.ok(guard >= 0 && guard < read, "the reader must reject non-regular files before reading");
});

test("the launch sequence is deterministic: attempt id, then launch, then launch flag, then polls", () => {
  const { context, events, run } = launchHarness();
  run();
  assert.deepEqual(events, ["launch-cleared", "exec-detached", "launched", "poll-start", "timeout-start"],
    "the gate must close at reset, and launch must precede the launch flag and both observation timers");
  assert.ok(context.installerAttemptId !== "", "an attempt id must exist");
  assert.equal(context.installerLaunched, true, "the launch gate must open only after execDetached");
  assert.equal(context.installingHelper, true);
  assert.equal(context.busy, true);
  assert.equal(context.statusText, "Opening the installer terminal…");
  assert.equal(context.installerPolls, 0);
});

test("a rejected launch logs, changes nothing, and starts no observation", () => {
  for (const guard of [{ busy: true }, { helperInstalled: true }]) {
    const { context, events, lines, run } = launchHarness(guard);
    run();
    assert.deepEqual(events, [], "a rejected launch must not spawn or start timers");
    assert.equal(context.installingHelper, false, "a rejected launch must not arm the flow");
    assert.equal(context.statusText, "", "a rejected launch must not touch the status line");
    assert.ok(lines.length >= 1 && /rejected/.test(lines[0]), "the rejection must be logged");
  }
});

test("result and lock observations are launch-gated", () => {
  const sealed = { root: { installerLaunched: false, installingHelper: true, installerAttemptId: "7", installerPolls: 0 },
    installerResultProbe: {}, installerLockProbe: {}, installerAttemptId: "7" };
  panelFunction("checkInstallerResult", sealed)();
  panelFunction("checkInstallerLock", sealed)();
  assert.deepEqual(sealed.installerResultProbe, {}, "no result read before launch");
  assert.deepEqual(sealed.installerLockProbe, {}, "no lock read before launch");

  const open = { root: { installerLaunched: true, installingHelper: true, installerAttemptId: "7", installerPolls: 5 },
    installerResultProbe: {}, installerLockProbe: {}, installerAttemptId: "7" };
  panelFunction("checkInstallerResult", open)();
  panelFunction("checkInstallerLock", open)();
  assert.equal(open.installerResultProbe.running, true, "result read starts after launch");
  const readCommand = Array.from(open.installerResultProbe.command);
  assert.equal(readCommand[0], "bash");
  assert.equal(readCommand[1], "-c");
  assert.ok(readCommand[2].includes("helper-install-result-$1"),
    "the result read must target the attempt-scoped result file");
  assert.equal(readCommand[readCommand.length - 1], "7",
    "the result read must carry the live attempt id as the script argument");
  assert.equal(open.installerLockProbe.running, true, "lock read starts after launch");
});

test("the poll tick cannot observe anything before launch", () => {
  const sealed = { root: { installerLaunched: false, installingHelper: true, installerAttemptId: "3", installerPolls: 0,
    checkHelper: function () { this.helperChecks = (this.helperChecks || 0) + 1; },
    checkInstallerResult: function () { this.resultReads = (this.resultReads || 0) + 1; },
    checkInstallerLock: function () { this.lockReads = (this.lockReads || 0) + 1; } } };
  timerHandler("installPoll", sealed)();
  assert.equal(sealed.root.installerPolls, 0, "no poll counting before launch");
  assert.equal(sealed.root.helperChecks, undefined, "no helper probe before launch");
  assert.equal(sealed.root.resultReads, undefined, "no result read before launch");
  assert.equal(sealed.root.lockReads, undefined, "no lock read before launch");

  const open = { root: { installerLaunched: true, installingHelper: true, installerAttemptId: "3", installerPolls: 0,
    checkHelper() {}, checkInstallerResult() {}, checkInstallerLock() {} } };
  timerHandler("installPoll", open)();
  assert.equal(open.root.installerPolls, 1, "polls count only after launch");
});

test("a result probe from a superseded attempt is dropped as stale", () => {
  const stopped = [];
  const log = logger();
  const context = {
    root: { installerLaunched: true, installingHelper: true, busy: true, installerFinished: false,
      installerTimedOut: true, installerPolls: 4,
      installerResultAttempt: "1000", installerAttemptId: "2000", statusText: "",
      checkHelper: () => { throw new Error("stale verdict must not recheck the helper"); } },
    installerResultOutput: { text: "success" },
    installPoll: { stop: () => stopped.push("poll") },
    installTimeout: { stop: () => stopped.push("timeout") },
    ...log,
  };
  probeExitHandler("installerResultProbe", context)();
  assert.deepEqual(stopped, [], "a stale verdict must stop nothing");
  assert.equal(context.root.statusText, "", "a stale verdict must not transition the status");
  assert.equal(context.root.busy, true, "a stale verdict must not release the UI");
  assert.equal(context.root.installerFinished, false, "a stale verdict must not finish the attempt");
  assert.ok(log.lines.some(line => /stale/.test(line)), "the drop must be logged");
});

test("every install status transition is logged and carries the observation that caused it", () => {
  function resultContext(verdict) {
    const log = logger();
    return { context: {
      root: { installerLaunched: true, installingHelper: true, busy: true, installerFinished: false,
        installerTimedOut: false, installerPolls: 2,
        installerResultAttempt: "9", installerAttemptId: "9", statusText: "", checkHelper() {} },
      installerResultOutput: { text: verdict },
      installPoll: { stop() {} }, installTimeout: { stop() {} },
      ...log,
    }, lines: log.lines };
  }

  let failure = resultContext("failure");
  probeExitHandler("installerResultProbe", failure.context)();
  assert.equal(failure.context.root.statusText, "Installation failed. Try again.");
  assert.ok(failure.lines.some(line => line.includes("installer status: Installation failed. Try again.")),
    "the failure transition must be logged");

  let success = resultContext("success");
  let rechecked = false;
  success.context.root.checkHelper = () => { rechecked = true; };
  probeExitHandler("installerResultProbe", success.context)();
  assert.equal(success.context.root.statusText, "Installer finished; checking hyprloom…");
  assert.equal(rechecked, true);
  assert.ok(success.lines.some(line => line.includes("result success")),
    "the observed verdict must be logged");

  const lockLog = logger();
  const lock = { root: { installerLaunched: true, installingHelper: true, busy: true, installerFinished: false,
    installerPolls: 6, installerAttemptId: "9", statusText: "" },
    installerLockOutput: { text: "free" }, installPoll: { stop() {} }, installTimeout: { stop() {} }, ...lockLog };
  probeExitHandler("installerLockProbe", lock)();
  assert.equal(lock.root.statusText, "Installer stopped before hyprloom was ready. Try again.");
  assert.ok(lockLog.lines.some(line => /lock free/.test(line)), "the lock observation must be logged");

  const timeoutLog = logger();
  let lockChecked = false;
  const timeout = { root: { installerLaunched: true, installingHelper: true, installerTimedOut: false,
    busy: false, installerPolls: 5, installerAttemptId: "9", statusText: "",
    checkInstallerLock: () => { lockChecked = true; } }, ...timeoutLog };
  timerHandler("installTimeout", timeout)();
  assert.equal(timeout.root.statusText, "Installation is still running…");
  assert.equal(timeout.root.installerTimedOut, true);
  assert.equal(lockChecked, true);
  assert.ok(timeoutLog.lines.some(line => /timed out/.test(line)), "the timeout decision must be logged");

  const readyLog = logger();
  let refreshed = false;
  const ready = { root: { helperInstalled: false, installingHelper: true, installerTimedOut: true, busy: true,
    statusText: "", refreshList: () => { refreshed = true; } },
    helperOutput: { text: "ready" }, installPoll: { stop() {} }, installTimeout: { stop() {} }, ...readyLog };
  probeExitHandler("helperCheck", ready)();
  assert.equal(ready.root.statusText, "hyprloom is ready.");
  assert.equal(refreshed, true);
  assert.ok(readyLog.lines.some(line => line.includes("installer status: hyprloom is ready.")),
    "the readiness transition must be logged");

  const missingLog = logger();
  const missing = { root: { helperInstalled: false, installingHelper: true, installerFinished: true, busy: true,
    statusText: "", snapshots: [] },
    helperOutput: { text: "missing" }, installPoll: { stop() {} }, installTimeout: { stop() {} }, ...missingLog };
  probeExitHandler("helperCheck", missing)();
  assert.equal(missing.root.statusText, "Installer finished but hyprloom is not available. Try again.");
  assert.ok(missingLog.lines.some(line => line.includes("installer status: Installer finished but hyprloom is not available. Try again.")),
    "the finished-but-missing transition must be logged");
});

test("launcher diagnostics stay sanitized: no paths, no shell fragments, no snapshot titles", () => {
  const { lines, run } = launchHarness();
  run();
  const failure = resultTransitionLogs();
  for (const line of [...lines, ...failure])
    assert.match(line, /^[^/$]*$/, `diagnostic must not contain path or shell characters: ${line}`);
});

// Collect transition logs from the failure and success exit paths for the
// sanitization sweep above.
function resultTransitionLogs() {
  const collected = [];
  for (const verdict of ["failure", "success"]) {
    const log = logger();
    const context = {
      root: { installerLaunched: true, installingHelper: true, busy: true, installerFinished: false,
        installerTimedOut: false, installerPolls: 1,
        installerResultAttempt: "5", installerAttemptId: "5", statusText: "", checkHelper() {} },
      installerResultOutput: { text: verdict },
      installPoll: { stop() {} }, installTimeout: { stop() {} },
      ...log,
    };
    probeExitHandler("installerResultProbe", context)();
    collected.push(...log.lines);
  }
  return collected;
}
