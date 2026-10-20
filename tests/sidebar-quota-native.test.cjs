const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

// Explicit GUI tests: only synthetic accounts and windows owned by this process.
for (const [name, flag] of [
  ['component', '--sidebar-quota-component-self-test'],
  ['presentation', '--sidebar-quota-presentation-self-test'],
  ['functional', '--sidebar-quota-functional-self-test'],
]) {
  test(`sidebar ${name}: isolated native regression`, () => {
    const output = process.env.OUTPUT_ROOT || path.resolve(__dirname, '../.build/tests');
    const binary = path.join(output, 'RootnoteResonanceDesktop');
    const result = spawnSync(binary, [flag, '--presentation-self-test'], {
      encoding: 'utf8', timeout: 60000,
      env: { ...process.env,
        ROOTNOTE_RESOURCES: path.resolve(__dirname, '../Resources'),
        ROOTNOTE_PANEL_STATE: path.join(output, `sidebar-${name}-state`),
      },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.ok, true);
    for (const [check, passed] of Object.entries(report.checks)) assert.equal(passed, true, check);
    report.binarySHA256 = crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex');
    fs.writeFileSync(path.join(output, `sidebar-${name}-report.json`), JSON.stringify(report, null, 2));
  });
}
