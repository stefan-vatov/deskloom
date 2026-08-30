// Stages only presentation assets; never loads the operational Panel or shell.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const stage = fs.mkdtempSync('/tmp/deskloom-report-fixture-');
// Unix-domain socket paths have a small length limit; keep runtime short.
const runtime = fs.mkdtempSync('/tmp/deskloom-report-');
const installed = '/usr/share/omarchy/shell';
for (const dir of ['cache', 'config']) fs.mkdirSync(path.join(stage, dir));
for (const dir of ['Commons', 'Ui']) fs.cpSync(path.join(installed, dir), path.join(stage, dir), { recursive: true });
let popup = fs.readFileSync(path.join(installed, 'Ui/PopupCard.qml'), 'utf8');
// Expose the real grab's active value without changing any behavior or handlers.
if (popup.split('HyprlandFocusGrab {').length !== 2) throw new Error('PopupCard structure changed');
popup = popup.replace('id: root', 'id: root\n  readonly property bool testGrabActive: testGrab.active')
  .replace('HyprlandFocusGrab {', 'HyprlandFocusGrab {\n    id: testGrab');
fs.writeFileSync(path.join(stage, 'Ui/PopupCard.qml'), popup);
for (const name of ['RestoreReportView.qml', 'RestoreReportPopup.qml', 'RestoreReport.js'])
  fs.copyFileSync(path.join(root, name), path.join(stage, name));
fs.copyFileSync(path.join(__dirname, 'real-popup.qml'), path.join(stage, 'shell.qml'));
const env = { ...process.env, QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: '',
  QT_QUICK_CONTROLS_STYLE: 'Basic', QT_QUICK_BACKEND: 'software', QML_DISABLE_DISK_CACHE: '1',
  XDG_RUNTIME_DIR: runtime, XDG_CACHE_HOME: path.join(stage, 'cache'),
  XDG_CONFIG_HOME: path.join(stage, 'config'), DESKLOOM_REPORT_ARTIFACT_DIR: __dirname };
for (const key of ['DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'DBUS_SESSION_BUS_ADDRESS',
  'QML_IMPORT_PATH', 'QML2_IMPORT_PATH', 'QS_CONFIG_PATH', 'QS_CONFIG_NAME']) delete env[key];
const result = spawnSync('/usr/bin/quickshell', ['--path', path.join(stage, 'shell.qml')], { env, encoding: 'utf8', timeout: 10000 });
const output = (result.stdout || '') + (result.stderr || '');
process.stdout.write(output);
fs.rmSync(stage, { recursive: true, force: true });
fs.rmSync(runtime, { recursive: true, force: true });
if (result.error || result.status !== 0 || !output.includes('REAL_POPUP_PASS:') || output.includes('REAL_POPUP_FAIL:')) {
  console.error(result.error || 'Real PopupCard smoke test failed');
  process.exitCode = 1;
}
