const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

test('native beacon glass, symbol sizing and click feedback survive both appearances', () => {
  const qa = process.env.OUTPUT_ROOT || path.resolve(__dirname, '../.build/tests');
  const binary = path.join(qa, 'RootnoteResonanceDesktop');
  const result = spawnSync(binary, ['--presentation-self-test'], {
    encoding: 'utf8',
    timeout: 30000,
    env: {
      ...process.env,
      ROOTNOTE_RESOURCES: path.resolve(__dirname, '../Resources'),
      ROOTNOTE_PANEL_STATE: path.join(qa, 'beacon-regression-state'),
    },
  });
  assert.ifError(result.error);
  const report = JSON.parse(result.stdout);
  report.binarySHA256 = crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex');
  fs.writeFileSync(path.join(qa, 'beacon-report.json'), JSON.stringify(report, null, 2));
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(report.ok, true);
  assert.equal(report.codexControlled, false);
  for (const theme of ['light', 'dark']) {
    for (const level of ['green', 'yellow', 'red']) {
      for (const check of ['glass_fills_circle', 'symbol_directly_hosted', 'native_symbol_fits', 'unmodified_native_glass', 'native_press_feedback']) {
        assert.equal(report.checks[`${theme}_${level}_${check}`], true);
      }
    }
  }
  for (const check of ['chrome_unmodified_native_glass', 'desktop_backdrop_sampling', 'no_mirrored_text_backdrop', 'content_does_not_overlap_navigation']) {
    assert.equal(report.checks[check], true);
  }
});
