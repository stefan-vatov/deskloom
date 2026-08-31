#!/usr/bin/env node
// Mounted over the helper only inside the test's private filesystem namespace.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const [operation, name] = process.argv.slice(2);
const argv = process.argv.slice(2);
if (operation === '--version') { console.log('hyprloom ' + process.env.FIXTURE_VERSION); process.exit(0); }
if (operation === '--help') process.exit(0);
if (operation === 'cache-update') {
  fs.writeFileSync(process.env.FIXTURE_DYNAMIC,
    'import QtQuick\nQtObject { property int revision: 2 }\n');
  fs.copyFileSync(process.env.FIXTURE_DYNAMIC,
    require('node:path').join(require('node:path').dirname(process.env.FIXTURE_DYNAMIC), 'RevisionTwo.qml'));
  process.exit(0);
}
if (operation === 'recover') {
  assert.deepEqual(argv, ['recover']);
  if (process.env.FIXTURE_RECOVER_FAIL === '1') {
    // Chunked, delayed, multiline stderr without a trailing newline.
    process.stderr.write('startup recovery step failed\n');
    const pad = Array.from({ length: 24 }, (_, i) => `remediation line ${i}: run hyprloom restore autosave-keep`).join('\n');
    setTimeout(() => {
      process.stderr.write(`safety snapshot: autosave-keep\n${pad}\nfinal manual step: hyprloom restore autosave-keep`);
      process.exit(1);
    }, 40);
    return;
  }
  process.exit(0);
}
if (operation === 'list') {
  assert.deepEqual(argv, ['list']);
  const deleted = new Set();
  try {
    for (const line of fs.readFileSync(process.env.FIXTURE_DESTRUCTIVE, 'utf8').split('\n')) {
      const [op, nm] = line.trim().split(' ');
      if (op === 'delete' && nm) deleted.add(nm);
    }
  } catch {}
  console.log('Saved sessions:');
  if (!deleted.has('fixture')) console.log('fixture — 2 windows (2026-08-30)');
  if (fs.existsSync(process.env.FIXTURE_STATE)) {
    const saved = JSON.parse(fs.readFileSync(process.env.FIXTURE_STATE, 'utf8')).name;
    if (!deleted.has(saved)) console.log(saved + ' — 2 windows (2026-08-30)');
  }
  let destructive = 0;
  try { destructive = fs.readFileSync(process.env.FIXTURE_DESTRUCTIVE, 'utf8').trim().split('\n').filter(Boolean).length; } catch {}
  if (destructive > 0) console.log('destructive-' + destructive + ' — 0 windows (counter)');
} else if (operation === 'replace' || operation === 'delete') {
  assert.deepEqual(argv, operation === 'replace' ? ['replace', name, '--report-json'] : ['delete', name]);
  fs.appendFileSync(process.env.FIXTURE_DESTRUCTIVE, operation + ' ' + name + '\n');
  if (name === 'failure') {
    console.error('Synthetic ' + operation + ' failure');
    process.exit(1);
  }
  process.exit(0);
} else if (operation === 'save' && ['native-save', 'failure', 'consent-save'].includes(name)) {
  assert.deepEqual(argv, ['save', name, '--force']);
  if (name === 'failure') {
    console.error('Synthetic save failure\n' + 'A detailed plain-text explanation <not markup>.\n'.repeat(24) + 'FINAL DIAGNOSTIC LINE');
    process.exit(1);
  }
  fs.writeFileSync(process.env.FIXTURE_STATE, JSON.stringify({ name }));
  console.log('Saved native-save');
} else if (operation === 'restore' && ['fixture', 'failure'].includes(name)) {
  assert.deepEqual(argv, ['restore', name, '--reconcile', '--report-json']);
  if (name === 'failure') {
    console.error('Synthetic restore failure');
    process.exit(1);
  }
  const windows = ['unchanged', 'launched'].map((status, index) => ({ workspace: 1,
    workspace_name: null, class: 'fixture', title: index ? 'New row' : 'Existing row',
    status, match_kind: null, message: null }));
  const output = JSON.stringify({ schema_version: 1, operation: 'reconcile', session: name,
    dry_run: false, recovery: null, report: { matched: 1, unchanged: 1, moved: 0,
      launched: 1, extras: 0, skipped: 0, failed: 0, windows } });
  // Multiple pipe writes, including a tail without a newline, exercise collection.
  process.stdout.write(output.slice(0, 30));
  setTimeout(() => process.stdout.write(output.slice(30)), 20);
} else {
  console.error('Forbidden fixture operation');
  process.exit(99);
}
