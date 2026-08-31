// Reusable hermetic production-boundary harness.
// Runs unchanged production artifacts inside a private, disposable sandbox
// and records redacted JSONL traces for every observed boundary.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createHash } = require('node:crypto');

const project = path.resolve(__dirname, '../..');

function fail(message) { throw new Error(message); }

// Unique, private, collision-safe sandbox beneath /tmp/${UID}.
function createStage() {
  const uid = typeof process.getuid === 'function' ? process.getuid() : 1000;
  const parent = path.join(os.tmpdir(), String(uid));
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  fs.chmodSync(parent, 0o700);
  const stage = fs.mkdtempSync(path.join(parent, 'deskloom-harness-'));
  fs.chmodSync(stage, 0o700);
  return stage;
}

function realpathInside(candidate, stage) {
  try { return fs.realpathSync(candidate).startsWith(fs.realpathSync(stage)); }
  catch { return false; }
}

// Refuse to launch unless every mutable endpoint lives inside the sandbox.
function preflight(stage, env) {
  for (const key of ['HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']) {
    if (!env[key]) fail(`preflight: ${key} is not set`);
    if (!realpathInside(env[key], stage)) fail(`preflight: ${key}=${env[key]} escapes the sandbox`);
  }
  const live = path.join(process.env.HOME ?? '', '.config/omarchy/plugins/thethracian.deskloom');
  if (realpathInside(live, stage)) fail('preflight: live plugin path resolved inside the sandbox');
}

// Every boundary observation is a TRACE record with a checked schema.
const TRACE_FIELDS = ['scenario', 'seq', 'instance', 'operation', 'transition', 'assertion'];
function validateTrace(record) {
  for (const field of TRACE_FIELDS)
    if (!(field in record)) fail(`trace: missing field ${field} in ${JSON.stringify(record)}`);
  if (typeof record.seq !== 'number' || record.seq < 0) fail(`trace: bad seq in ${JSON.stringify(record)}`);
  for (const field of ['scenario', 'instance', 'operation', 'transition', 'assertion'])
    if (typeof record[field] !== 'string') fail(`trace: ${field} must be a string`);
  return record;
}

function createHarness({ scenarios = [], keepStage = false, quiet = false } = {}) {
  const stage = createStage();
  const traces = [];
  const seqCounters = new Map();
  let cleaned = false;

  const env = { HOME: path.join(stage, 'home'), PATH: '/usr/bin:/bin', LANG: 'C.UTF-8',
    QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: '',
    QT_QUICK_CONTROLS_STYLE: 'Basic', QT_QUICK_BACKEND: 'software', QML_DISABLE_DISK_CACHE: '1',
    XDG_RUNTIME_DIR: path.join(stage, 'runtime'), XDG_CONFIG_HOME: path.join(stage, 'config'),
    XDG_CACHE_HOME: path.join(stage, 'cache'), XDG_STATE_HOME: path.join(stage, 'state'),
    XDG_DATA_HOME: path.join(stage, 'data'), FIXTURE_NODE: process.execPath,
    FIXTURE_HELPER: path.join(stage, 'helper.cjs'), FIXTURE_DYNAMIC: path.join(stage, 'dynamic.qml'),
    FIXTURE_PANEL: path.join(stage, 'production', 'Panel.qml'), FIXTURE_STATE: path.join(stage, 'saved.json'),
    FIXTURE_DESTRUCTIVE: path.join(stage, 'destructive.txt') };

  function cleanup() {
    if (cleaned) return;
    cleaned = true;
    if (!keepStage) fs.rmSync(stage, { recursive: true, force: true });
  }

  function trace(record) {
    const full = validateTrace(record);
    const key = `${full.scenario}/${full.instance}`;
    const next = (seqCounters.get(key) ?? -1) + 1;
    if (full.seq !== next) fail(`trace: ${key} seq ${full.seq} out of order, expected ${next}`);
    seqCounters.set(key, next);
    traces.push(full);
  }

  // Substitutes only external services: isolated helper/storage, fake
  // registry endpoint, controlled barriers. Production files are copied,
  // never function-extracted.
  function setup() {
    fs.mkdirSync(path.join(stage, 'home'));
    for (const dir of ['runtime', 'config', 'cache', 'state', 'data', 'production'])
      fs.mkdirSync(path.join(stage, dir), { mode: 0o700 });
    for (const dir of ['Commons', 'Ui'])
      fs.cpSync('/usr/share/omarchy/shell/' + dir, path.join(stage, dir), { recursive: true });
    for (const name of ['Panel.qml', 'RestoreReport.js', 'RestoreReportPopup.qml', 'RestoreReportView.qml'])
      fs.copyFileSync(path.join(project, name), path.join(stage, 'production', name));
    fs.copyFileSync(path.join(__dirname, 'helper.cjs'), env.FIXTURE_HELPER);
    fs.chmodSync(env.FIXTURE_HELPER, 0o755);
    const panel = fs.readFileSync(env.FIXTURE_PANEL, 'utf8');
    env.FIXTURE_VERSION = panel.match(/helperVersion: "([^"]+)"/)[1];
    const commit = panel.match(/helperSourceCommit: "([^"]+)"/)[1];
    const hash = createHash('sha256').update(fs.readFileSync(env.FIXTURE_HELPER)).digest('hex');
    fs.writeFileSync(path.join(stage, 'helper.sha256'), `${commit} ${hash}\n`, { mode: 0o600 });
    fs.writeFileSync(env.FIXTURE_DYNAMIC, 'import QtQuick\nQtObject { property int revision: 1 }\n');
    fs.writeFileSync(path.join(stage, 'RevisionTwo.qml'), 'import QtQuick\nQtObject { property int revision: 1 }\n');
    preflight(stage, env);
  }

  // Runs one scenario: an unchanged shell.qml against the doubled boundaries.
  // Async spawn keeps the event loop live so SIGTERM/SIGINT handlers can clean
  // up while a scenario executes.
  function run(name, { fakeHelper = true, extraEnv = {}, timeoutMs = 15000 } = {}) {
    const scenarioPath = path.isAbsolute(name) ? name : path.resolve(__dirname, name);
    fs.copyFileSync(scenarioPath, path.join(stage, 'shell.qml'));
    const command = [
      '--unshare-all', '--die-with-parent', '--new-session', '--ro-bind', '/', '/',
      '--bind', stage, stage, '--tmpfs', '/run', '--proc', '/proc', '--dev', '/dev'];
    if (fakeHelper) {
      command.push('--ro-bind', env.FIXTURE_HELPER, path.join(env.HOME, '.local/bin/hyprloom'),
        '--ro-bind', path.join(stage, 'helper.sha256'), path.join(env.HOME, '.local/bin/.hyprloom.sha256'));
    } else if (process.env.DESKLOOM_TEST_HELPER_ROOT) {
      command.push('--ro-bind', path.join(process.env.DESKLOOM_TEST_HELPER_ROOT, 'bin/hyprloom'), path.join(env.HOME, '.local/bin/hyprloom'),
        '--ro-bind', path.join(process.env.DESKLOOM_TEST_HELPER_ROOT, 'bin/.hyprloom.sha256'), path.join(env.HOME, '.local/bin/.hyprloom.sha256'));
    }
    command.push('/usr/bin/quickshell', '--path', path.join(stage, 'shell.qml'));
    return new Promise((resolve, reject) => {
      let output = '';
      const child = spawn('/usr/bin/bwrap', command, { env: { ...env, ...extraEnv } });
      const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
      child.stdout.on('data', d => { output += d; });
      child.stderr.on('data', d => { output += d; });
      child.on('error', e => { clearTimeout(timer); reject(e); });
      child.on('exit', (code, signal) => {
        clearTimeout(timer);
        process.stdout.write(output);
        for (const line of output.split('\n')) {
          const at = line.indexOf('TRACE ');
          if (at < 0) continue;
          trace(JSON.parse(line.slice(at + 6)));
        }
        if (code !== 0 || signal || !output.includes('NATIVE_PASS') || output.includes('NATIVE_FAIL')
            || /\b(?:TypeError|ReferenceError|SyntaxError):|Unable to assign|FAIL!/.test(output)) {
          reject(new Error(`${name} failed (code=${code} signal=${signal})`));
        } else {
          resolve(output);
        }
      });
    });
  }

  function finish() {
    for (const record of traces)
      process.stdout.write('JSONL ' + JSON.stringify(record) + '\n');
    cleanup();
  }

  function cleanupOnSignal(signal) {
    cleanup();
    process.stderr.write(`harness: ${signal} received; sandbox cleaned\n`);
    process.exit(1);
  }
  process.on('SIGTERM', () => cleanupOnSignal('SIGTERM'));
  process.on('SIGINT', () => cleanupOnSignal('SIGINT'));

  return { stage, env, setup, run, trace, finish, cleanup, get cleaned() { return cleaned; },
    get traces() { return traces; } };
}

module.exports = { createHarness, preflight, validateTrace, project };
