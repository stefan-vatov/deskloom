import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import test from "node:test";

const { parse } = createRequire(import.meta.url)("../RestoreReport.js");

test("real Hyprloom JSON is consumed by Deskloom's presentation model", { skip: !process.env.HYPRLOOM_BIN }, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-cli-report-"));
  try {
    const sessions = path.join(root, "data/hyprloom/sessions");
    const bin = path.join(root, "bin");
    fs.mkdirSync(sessions, { recursive: true, mode: 0o700 });
    fs.mkdirSync(bin);
    const target = {
      class: "foot", title: "Editor <project> — София", address: "0xfixture", stable_id: "fixture",
      initial_class: "foot", initial_title: "foot", workspace: 3, workspace_name: "3", monitor: "DP-1",
      at: [10, 20], size: [800, 600], floating: false, fullscreen: 0, focus_history_id: 0,
      launch: { command: "foot", args: [], hint: null },
    };
    fs.writeFileSync(path.join(sessions, "coding.json"), JSON.stringify({
      name: "coding", created_at: "2026-01-01T00:00:00Z", hyprland_version: "fixture", monitors: [], clients: [target],
    }), { mode: 0o600 });
    fs.writeFileSync(path.join(root, "clients.json"), JSON.stringify([{
      address: "0xfixture", stableId: "fixture", class: target.class, title: target.title,
      initialClass: "foot", initialTitle: "foot", workspace: { id: 3, name: "3" }, monitor: 0,
      at: target.at, size: target.size, floating: false, fullscreen: 0, focusHistoryID: 0, pid: 0,
    }]));
    fs.writeFileSync(path.join(bin, "hyprctl"), `#!/bin/sh
set -eu
case "$1" in
  clients) cat "$DESKLOOM_REPORT_FIXTURE/clients.json" ;;
  monitors) printf '%s\\n' '[{"id":0,"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"transform":0}]' ;;
  getoption) [ "$2" = general.layout ]; printf '%s\\n' 'str: dwindle' 'set: true' ;;
  *) printf '%s\\n' "$*" >> "$DESKLOOM_REPORT_FIXTURE/unexpected"; exit 1 ;;
esac
`, { mode: 0o755 });

    const result = spawnSync(process.env.HYPRLOOM_BIN, ["restore", "coding", "--reconcile", "--report-json", "--verbose"], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, DESKLOOM_REPORT_FIXTURE: root,
        XDG_DATA_HOME: path.join(root, "data"), XDG_CONFIG_HOME: path.join(root, "config"), XDG_RUNTIME_DIR: path.join(root, "runtime") },
      encoding: "utf8",
    });
    const model = parse(result.stdout, result.status, result.stderr, "coding");

    assert.equal(result.status, 0, result.stderr);
    assert.equal(model.available, true);
    assert.equal(model.hasIssues, false);
    assert.equal(model.counts.unchanged, 1);
    assert.equal(model.counts.launched, 0);
    assert.equal(model.groups[0].label, "Workspace 3");
    assert.equal(model.groups[0].windows[0].title, target.title);
    assert.equal(model.groups[0].windows[0].label, "Found existing");
    assert.equal(fs.existsSync(path.join(root, "unexpected")), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
