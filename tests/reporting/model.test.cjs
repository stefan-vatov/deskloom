const { test } = require('node:test');
const assert = require('node:assert/strict');
const Model = require('../../RestoreReport.js');

function fixture() {
  return { schema_version: 1, operation: 'reconcile', session: 'work', dry_run: false,
    report: { matched: 1, unchanged: 1, moved: 0, launched: 0, extras: 0, skipped: 0, failed: 0,
      windows: [{ workspace: 2, workspace_name: null, class: 'terminal', title: 'Notes',
        status: 'unchanged', match_kind: 'exact', message: null }] }, recovery: null };
}

test('one existing window becomes a labeled workspace row', () => {
  const model = Model.parse(JSON.stringify(fixture()), 0, '', 'work');
  assert.equal(model.available, true);
  assert.equal(model.hasIssues, false);
  assert.match(model.summaryText, /Found existing/);
  assert.deepEqual(model.counts, { matched: 1, unchanged: 1, moved: 0, launched: 0, extras: 0, skipped: 0, failed: 0 });
  assert.equal(model.groups[0].label, 'Workspace 2');
  assert.equal(model.groups[0].windows[0].label, 'Found existing');
  assert.equal(model.groups[0].windows[0].title, 'Notes');
});

test('invalid or unsupported data never reports success', () => {
  const variants = ['', 'log output', '{}', 'null', '[]'];
  for (const mutate of [
    p => p.schema_version = 2,
    p => delete p.report,
    p => p.report.windows = {},
    p => p.report.failed = -1,
    p => p.report.moved = 0.5,
    p => delete p.report.matched,
    p => p.dry_run = 'false',
    p => p.operation = 'delete',
    p => delete p.session,
    p => delete p.recovery,
    p => p.recovery = 'unknown',
    p => p.report.windows[0].workspace = '2',
    p => delete p.report.windows[0].title,
    p => p.report.windows[0].status = 'success',
    p => p.report.windows[0].message = {},
    p => delete p.report.windows[0].match_kind,
    p => p.report.windows[0].workspace_name = 2
  ]) {
    const payload = fixture(); mutate(payload); variants.push(JSON.stringify(payload));
  }
  for (const output of variants) {
    const model = Model.parse(output, 0, 'Details could not be read', 'fallback');
    assert.equal(model.available, false, output);
    assert.equal(model.complete, false);
    assert.equal(model.hasIssues, true);
    assert.equal(model.diagnostic, 'Details could not be read');
    assert.equal(model.counts, null);
    assert.equal(model.title, 'Report unavailable');
    assert.equal(model.session, 'fallback');
    assert.match(model.detail, /Details could not be read/);
    assert.deepEqual(model.groups, []);
  }
});

test('all statuses, Unicode, empty titles, and named workspaces remain truthful', () => {
  const payload = fixture();
  const statuses = ['unchanged', 'moved', 'launched', 'extra', 'skipped', 'failed'];
  payload.report.windows = statuses.map((status, i) => ({ ...fixture().report.windows[0],
    workspace: i === 0 ? 10 : 2, workspace_name: i === 0 ? '日本語' : null,
    title: i === 0 ? '' : '<b>λ & 🦊</b>', status, message: i === 5 ? 'App unavailable' : null }));
  Object.assign(payload.report, { matched: 2, moved: 1, launched: 1, extras: 1, failed: 1, skipped: 1 });
  const model = Model.parse(JSON.stringify(payload), 0, '', '');
  assert.equal(model.groups[0].label, 'Workspace 2');
  assert.equal(model.groups[1].label, 'Workspace 日本語');
  assert.equal(model.groups[1].windows[0].title, '(Untitled window)');
  assert.equal(model.groups[0].windows[0].title, '<b>λ & 🦊</b>');
  assert.deepEqual(model.groups[0].windows.map(w => w.label),
    ['Adjusted existing', 'Restored', 'Left alone', 'Skipped', 'Failed']);
  assert.equal(model.complete, false);
});

test('exit failure, skipped rows and recovery cannot masquerade as completion', () => {
  for (const recovery of [null, 'succeeded', 'failed']) {
    const payload = fixture(); payload.recovery = recovery;
    const model = Model.parse(JSON.stringify(payload), 1, 'Launch failed', '');
    assert.equal(model.complete, false);
    assert.match(model.detail, /Launch failed/);
    if (recovery === 'failed') assert.match(model.detail, /Recovery failed/);
    if (recovery === 'succeeded') assert.match(model.detail, /Recovery succeeded/);
  }
  const payload = fixture(); payload.report.windows[0].status = 'failed';
  payload.report.unchanged = 0; payload.report.failed = 1;
  assert.equal(Model.parse(JSON.stringify(payload), 0, '', '').complete, false);
});

test('preview uses planned language and tolerates future metadata', () => {
  const payload = fixture(); payload.dry_run = true;
  payload.report.windows[0].status = 'launched'; payload.operation = 'replace';
  payload.report.unchanged = 0; payload.report.launched = 1; payload.report.matched = 0;
  payload.errors = [{ message: 'future metadata' }]; payload.report.future = true;
  const model = Model.parse(JSON.stringify(payload), 0, '', '');
  assert.equal(model.title, 'Restore preview');
  assert.match(model.detail, /No changes were executed/);
  assert.equal(model.groups[0].windows[0].label, 'Would restore');
  assert.doesNotMatch(model.summary, /Restored/);
});

test('empty reports and 1024 rows are supported; oversized lists are rejected', () => {
  const payload = fixture(); payload.report.windows = [];
  payload.report.unchanged = 0; payload.report.matched = 0;
  assert.deepEqual(Model.parse(JSON.stringify(payload), 0, '', '').groups, []);
  payload.report.windows = Array.from({ length: 1024 }, () => fixture().report.windows[0]);
  payload.report.windows = payload.report.windows.map((row, index) => ({ ...row, status: index < 512 ? 'unchanged' : 'extra' }));
  payload.report.unchanged = 512; payload.report.extras = 512; payload.report.matched = 512;
  assert.equal(Model.parse(JSON.stringify(payload), 0, '', '').groups[0].windows.length, 1024);
  payload.report.windows.push(fixture().report.windows[0]);
  assert.equal(Model.parse(JSON.stringify(payload), 0, '', '').available, false);
});

test('numeric workspace names coalesce with IDs while named workspaces stay distinct', () => {
  const payload = fixture();
  payload.report.windows = [null, '2', 'research'].map(workspace_name => ({ ...fixture().report.windows[0], workspace_name }));
  payload.report.unchanged = 3; payload.report.matched = 3;
  const model = Model.parse(JSON.stringify(payload), 0, '', '');
  assert.equal(model.groups.length, 2);
  assert.equal(model.groups[0].windows.length, 2);
  assert.equal(model.groups[1].label, 'Workspace research');
});

test('summary counters must match rows, with failed matches allowed to overlap', () => {
  const missing = fixture(); missing.report.windows = [];
  assert.equal(Model.parse(JSON.stringify(missing), 0, '', '').available, false);
  for (const counter of ['unchanged', 'moved', 'launched', 'extras', 'skipped', 'failed']) {
    const payload = fixture(); payload.report[counter]++;
    assert.equal(Model.parse(JSON.stringify(payload), 0, '', '').available, false, counter);
  }
  for (const matched of [0, 2]) {
    const payload = fixture(); payload.report.matched = matched;
    assert.equal(Model.parse(JSON.stringify(payload), 0, '', '').available, false);
  }
  for (const matched of [1, 2]) {
    const payload = fixture(); payload.report.matched = matched; payload.report.failed = 1;
    payload.report.windows.push({ ...payload.report.windows[0], status: 'failed' });
    const model = Model.parse(JSON.stringify(payload), 1, 'Failed', '');
    assert.equal(model.available, true);
    assert.equal(model.hasIssues, true);
  }
});
