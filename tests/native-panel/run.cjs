// Entry point for the native production-boundary suite. The reusable core
// lives in harness.cjs; scenarios own their behavioral assertions.
const { createHarness } = require('./harness.cjs');
const path = require('node:path');
const fs = require('node:fs');

const keepStage = !!process.env.KEEP_STAGE;
const harness = createHarness({ keepStage });
const { env, stage } = harness;

(async () => {
  try {
    harness.setup();
    await harness.run('cache.qml');
    // Compile original bytes first. Never remove or merge duplicate handlers here.
    await harness.run('compile.qml');
    await harness.run('commands.qml');
    await harness.run('fixture.qml');
    await harness.run('consent.qml');
    await harness.run('recovery.qml', { extraEnv: { FIXTURE_RECOVER_FAIL: '1' } });
    await harness.run('instances.qml', { extraEnv: { FIXTURE_BARRIER: path.join(stage, 'barrier') } });

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
      await harness.run('fixture.qml', { fakeHelper: false });
      const saved = JSON.parse(fs.readFileSync(path.join(sessions, 'native-save.json')));
      if (saved.name !== 'native-save' || saved.clients.length !== 1
          || fs.readFileSync(path.join(sessions, 'fixture.json'), 'utf8') !== preset
          || fs.existsSync(env.FIXTURE_UNEXPECTED)) throw new Error('Real CLI state mismatch: ' + JSON.stringify({
            name: saved.name, clients: saved.clients.length,
            presetUnchanged: fs.readFileSync(path.join(sessions, 'fixture.json'), 'utf8') === preset,
            unexpected: fs.existsSync(env.FIXTURE_UNEXPECTED) ? fs.readFileSync(env.FIXTURE_UNEXPECTED, 'utf8') : null
          }));
    }

    if (harness.traces.length === 0) throw new Error('harness produced no trace records');
    harness.finish();
  } catch (error) {
    console.error(error.message);
    harness.cleanup();
    process.exitCode = 1;
  }
})();
