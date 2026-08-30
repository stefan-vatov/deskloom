import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("../", import.meta.url));
const reportingFiles = ["RestoreReport.js", "RestoreReportView.qml", "RestoreReportPopup.qml"];

test("local installer deploys all report components as a complete plugin", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deskloom-report-install-"));
  try {
    const bin = path.join(root, "bin");
    const config = path.join(root, "config");
    const runtime = path.join(root, "runtime");
    const source = path.join(root, "source");
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime);
    fs.mkdirSync(source);
    for (const file of ["install-local.sh", "install-helper.sh", "manifest.json", "README.md", "Panel.qml", ...reportingFiles])
      fs.copyFileSync(path.join(project, file), path.join(source, file));
    fs.writeFileSync(path.join(bin, "omarchy"), `#!/bin/sh
set -eu
case "$1 $2" in
  'plugin validate')
    entry=$(jq -r '.entryPoints.barWidget' "$3/manifest.json")
    bundle=$(dirname "$3/$entry")
    for file in RestoreReport.js RestoreReportView.qml RestoreReportPopup.qml; do
      test -f "$bundle/$file" || { echo "missing report asset: $file" >&2; exit 1; }
    done
    ;;
  'plugin list') printf '%s\\n' '[{"id":"thethracian.deskloom","enabled":true}]' ;;
  *) echo 'unexpected plugin mutation' >&2; exit 1 ;;
esac
`, { mode: 0o755 });
    fs.writeFileSync(path.join(bin, "omarchy-shell"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });

    const install = () => spawnSync("bash", [path.join(source, "install-local.sh")], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, XDG_CONFIG_HOME: config, XDG_RUNTIME_DIR: runtime },
      encoding: "utf8",
    });
    const result = install();

    assert.equal(result.status, 0, result.stderr);
    const installed = path.join(config, "omarchy/plugins/thethracian.deskloom");
    const entryPoint = () => JSON.parse(fs.readFileSync(path.join(installed, "manifest.json"))).entryPoints.barWidget;
    const firstEntry = entryPoint();
    assert.match(firstEntry, /^runtime\/[a-f0-9]{64}\/Panel\.qml$/);
    for (const file of reportingFiles)
      assert.deepEqual(fs.readFileSync(path.join(installed, path.dirname(firstEntry), file)), fs.readFileSync(path.join(project, file)));
    assert.equal(fs.existsSync(path.join(config, "omarchy/.deskloom-rollback/transaction")), false);

    assert.equal(install().status, 0);
    assert.equal(entryPoint(), firstEntry, "identical runtime content retains its identity");
    fs.appendFileSync(path.join(source, "RestoreReport.js"), "\n// changed fixture content\n");
    assert.equal(install().status, 0);
    assert.notEqual(entryPoint(), firstEntry, "import changes must force a fresh QML URL");
    assert.equal(fs.existsSync(path.join(installed, firstEntry)), false, "obsolete bundle is not retained");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
