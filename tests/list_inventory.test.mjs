// Machine inventory consumption: Panel parses hyprloom's versioned
// list --json output, rejects malformed responses without mutating the
// model, and retains the last known-good rows (beads 081.15 + 081.4).
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

function inventoryHarness(prior = [{ name: "old", windows: 2, created: "yesterday", automatic: false }]) {
  const context = {
    snapshots: prior,
    snapshotsLoaded: true,
    snapshotListFailed: false,
    busy: false,
    defaultPreset: "",
    statusText: "",
    persistSettings() { context.persisted = true; },
    root: null,
  };
  context.root = context;
  return { context, parse: vm.runInNewContext(`(function(output) {${source.match(/  function parseInventory\(output\) \{([\s\S]*?)\n  \}/)[1]}\n})`, context) };
}

const DOC = rows => JSON.stringify({
  schema_version: 1, protocol: "deskloom.inventory",
  sessions: rows.map(([name, windows, created, automatic]) => ({ name, windows, created, automatic })),
});
const OK = DOC([["work", 3, "2026-01-01", false], ["auto-1", 0, "2026-01-02", true]]);

test("a valid populated inventory commits rows with revision-bearing fields", () => {
  const h = inventoryHarness();
  h.parse(OK);
  assert.equal(h.context.snapshots.length, 2);
  assert.deepEqual(
    JSON.parse(JSON.stringify(h.context.snapshots.map(s => [s.name, s.windows, s.automatic]))),
    [["work", 3, false], ["auto-1", 0, true]]);
  assert.equal(typeof h.context.snapshots[0].revision, "string");
  assert.equal(h.context.snapshotsLoaded, true);
  assert.equal(h.context.snapshotListFailed, false);
});

test("a valid empty inventory commits zero rows without failing", () => {
  const h = inventoryHarness([]);
  h.parse(DOC([]));
  assert.deepEqual(JSON.parse(JSON.stringify(h.context.snapshots)), []);
  assert.equal(h.context.snapshotsLoaded, true);
  assert.equal(h.context.snapshotListFailed, false);
});

for (const [name, payload] of [
  ["malformed json", "{not json"],
  ["truncated json", '{"schema_version":1,"protocol":"deskloom.inventory","sessions":[{"name":"wo'],
  ["an object that is not an inventory", '{"unexpected":true}'],
  ["a wrong protocol name", JSON.stringify({ schema_version: 1, protocol: "other", sessions: [] })],
  ["an unsupported schema version", JSON.stringify({ schema_version: 2, protocol: "deskloom.inventory", sessions: [] })],
  ["sessions that is not an array", JSON.stringify({ schema_version: 1, protocol: "deskloom.inventory", sessions: {} })],
  ["a record missing its name", JSON.stringify({ schema_version: 1, protocol: "deskloom.inventory", sessions: [{ windows: 1 }] })],
  ["a record with a non-numeric window count", JSON.stringify({ schema_version: 1, protocol: "deskloom.inventory", sessions: [{ name: "x", windows: "many" }] })],
  ["duplicate names", DOC([["work", 1, "c", false], ["work", 2, "c", false]])],
]) {
  test(`inventory rejection: ${name} keeps the last known-good rows`, () => {
    const harness = inventoryHarness([{ name: "known-good", windows: 1, created: "c", automatic: false }]);
    const before = harness.context.snapshots;
    harness.parse(payload);
    assert.deepEqual(harness.context.snapshots, before, "the prior model must survive a rejected response");
    assert.equal(harness.context.snapshotListFailed, true, "the rejection must be visible as a failure");
  });
}
