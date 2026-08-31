// Real Panel + real Quickshell Process; never connects to the user's shell.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const stage = fs.mkdtempSync('/tmp/deskloom-native-');
function run(name, fakeHelper = true, extraEnv = {}) {
  fs.copyFileSync(path.join(__dirname, name), path.join(stage, 'shell.qml'));
  const result = spawnSync('/usr/bin/bwrap', [
    '--unshare-all', '--die-with-parent', '--new-session', '--ro-bind', '/', '/',
    '--bind', stage, stage, '--tmpfs', '/run', '--proc', '/proc', '--dev', '/dev',
    ...(fakeHelper ? [
      '--ro-bind', env.FIXTURE_HELPER, path.join(process.env.HOME, '.local/bin/hyprloom'),
      '--ro-bind', path.join(stage, 'helper.sha256'), path.join(process.env.HOME, '.local/bin/.hyprloom.sha256')
    ] : process.env.DESKLOOM_TEST_HELPER_ROOT ? [
      '--ro-bind', path.join(process.env.DESKLOOM_TEST_HELPER_ROOT, 'bin/hyprloom'), path.join(process.env.HOME, '.local/bin/hyprloom'),
      '--ro-bind', path.join(process.env.DESKLOOM_TEST_HELPER_ROOT, 'bin/.hyprloom.sha256'), path.join(process.env.HOME, '.local/bin/.hyprloom.sha256')
    ] : []),
    '/usr/bin/quickshell', '--path', path.join(stage, 'shell.qml')],
    { env: { ...env, ...extraEnv }, encoding: 'utf8', timeout: 15000 });
  const output = (result.stdout || '') + (result.stderr || '');
  process.stdout.write(output);
  if (result.error || result.status !== 0 || !output.includes('NATIVE_PASS') || output.includes('NATIVE_FAIL')
      || /\b(?:TypeError|ReferenceError|SyntaxError):|Unable to assign|FAIL!/.test(output))
    throw new Error(result.error?.message || `${name} failed`);
}
const env = { HOME: process.env.HOME, PATH: '/usr/bin:/bin', LANG: 'C.UTF-8',
  QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: '',
  QT_QUICK_CONTROLS_STYLE: 'Basic', QT_QUICK_BACKEND: 'software', QML_DISABLE_DISK_CACHE: '1',
  XDG_RUNTIME_DIR: path.join(stage, 'runtime'), XDG_CONFIG_HOME: path.join(stage, 'config'),
  XDG_CACHE_HOME: path.join(stage, 'cache'), XDG_STATE_HOME: path.join(stage, 'state'),
  XDG_DATA_HOME: path.join(stage, 'data'), FIXTURE_NODE: process.execPath,
  FIXTURE_HELPER: path.join(stage, 'helper.cjs'), FIXTURE_DYNAMIC: path.join(stage, 'dynamic.qml'),
  FIXTURE_PANEL: path.join(stage, 'production', 'Panel.qml'), FIXTURE_STATE: path.join(stage, 'saved.json'),
  FIXTURE_DESTRUCTIVE: path.join(stage, 'destructive.txt') };
try {
  for (const dir of ['runtime', 'config', 'cache', 'state', 'data', 'production'])
    fs.mkdirSync(path.join(stage, dir), { mode: 0o700 });
  for (const dir of ['Commons', 'Ui'])
    fs.cpSync(`/usr/share/omarchy/shell/${dir}`, path.join(stage, dir), { recursive: true });
  for (const name of ['Panel.qml', 'RestoreReport.js', 'RestoreReportPopup.qml', 'RestoreReportView.qml'])
    fs.copyFileSync(path.join(root, name), path.join(stage, 'production', name));
  fs.copyFileSync(path.join(__dirname, 'helper.cjs'), env.FIXTURE_HELPER);
  fs.chmodSync(env.FIXTURE_HELPER, 0o755);
  const panel = fs.readFileSync(env.FIXTURE_PANEL, 'utf8');
  env.FIXTURE_VERSION = panel.match(/helperVersion: "([^"]+)"/)[1];
  const commit = panel.match(/helperSourceCommit: "([^"]+)"/)[1];
  const hash = createHash('sha256').update(fs.readFileSync(env.FIXTURE_HELPER)).digest('hex');
  fs.writeFileSync(path.join(stage, 'helper.sha256'), `${commit} ${hash}\n`, { mode: 0o600 });
  fs.writeFileSync(env.FIXTURE_DYNAMIC, 'import QtQuick\nQtObject { property int revision: 1 }\n');
  fs.writeFileSync(path.join(stage, 'RevisionTwo.qml'), 'import QtQuick\nQtObject { property int revision: 1 }\n');
  run('cache.qml');
  // Compile original bytes first. Never remove or merge duplicate handlers here.
  run('compile.qml');
  run('commands.qml');
  run('fixture.qml');
  run('consent.qml');
  run('recovery.qml', true, { FIXTURE_RECOVER_FAIL: '1' });
  if (process.env.DESKLOOM_TEST_INSTALLED_HELPER === '1') {
    const sessions = path.join(env.XDG_DATA_HOME, 'hyprloom/sessions');
    const bin = path.join(stage, 'bin');
    fs.mkdirSync(sessions, { recursive: true, mode: 0o700 });
    fs.mkdirSync(bin);
    const target = { class: 'foot', title: 'Editor — native fixture', address: '0xfixture', stable_id: 'fixture',
      initial_class: 'foot', initial_title: 'foot', workspace: 3, workspace_name: '3', monitor: 'DP-1',
      at: [10, 20], size: [800, 600], floating: false, fullscreen: 0, focus_history_id: 0,
      launch: { command: 'foot', args: [], hint: null } };
    const preset = JSON.stringify({ name: 'fixture', created_at: '2026-01-01T00:00:00Z',
      hyprland_version: 'fixture', monitors: [], clients: [target] });
    fs.writeFileSync(path.join(sessions, 'fixture.json'), preset, { mode: 0o600 });
    env.FIXTURE_CLIENTS = path.join(stage, 'clients.json');
    env.FIXTURE_UNEXPECTED = path.join(stage, 'unexpected-compositor-call');
    fs.writeFileSync(env.FIXTURE_CLIENTS, JSON.stringify([{ address: target.address, stableId: target.stable_id,
      class: target.class, title: target.title, initialClass: 'foot', initialTitle: 'foot',
      workspace: { id: 3, name: '3' }, monitor: 0, at: target.at, size: target.size,
      floating: false, fullscreen: 0, focusHistoryID: 0, pid: 0 }]));
    fs.copyFileSync(path.join(__dirname, 'hyprctl.cjs'), path.join(bin, 'hyprctl'));
    fs.chmodSync(path.join(bin, 'hyprctl'), 0o755);
    env.PATH = `${bin}:/usr/bin:/bin`;
    env.FIXTURE_REAL_CLI = '1';
    run('fixture.qml', false);
    const saved = JSON.parse(fs.readFileSync(path.join(sessions, 'native-save.json')));
    if (saved.name !== 'native-save' || saved.clients.length !== 1
        || fs.readFileSync(path.join(sessions, 'fixture.json'), 'utf8') !== preset
        || fs.existsSync(env.FIXTURE_UNEXPECTED)) throw new Error('Real CLI state mismatch: ' + JSON.stringify({
          name: saved.name, clients: saved.clients.length,
          presetUnchanged: fs.readFileSync(path.join(sessions, 'fixture.json'), 'utf8') === preset,
          unexpected: fs.existsSync(env.FIXTURE_UNEXPECTED) ? fs.readFileSync(env.FIXTURE_UNEXPECTED, 'utf8') : null
        }));
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (!process.env.KEEP_STAGE) fs.rmSync(stage, { recursive: true, force: true });
}
