'use strict';
// DOM tests for the actual emitted suite, not a separately implemented mock.
// Generate the preview with tools/render_demo.py before running this file.
// Usage: node tests/suite_layout_regression.js path/to/preview-directory
// Requires jsdom; DOM checks do not replace browser rendering or Stata execution.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');
const dir = path.resolve(process.argv[2] || 'examples/paradata-preview');
const errors = [];
const vc = new VirtualConsole();
vc.on('jsdomError', e => errors.push(e.message));
const dom = new JSDOM(fs.readFileSync(path.join(dir, 'paradata-example.html'), 'utf8'), {
  runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
  beforeParse(w) { w.TextDecoder = TextDecoder; w.TextEncoder = TextEncoder; }
});
const w = dom.window;
const doc = w.document;
function change(el, val) { el.value = val; el.dispatchEvent(new el.ownerDocument.defaultView.Event('change', { bubbles: true })); }
try {
  const frames = [...doc.querySelectorAll('.pane iframe')];
  assert.equal(frames.length, 3);
  assert(frames.every(f => f.title && f.title.length > 5));
  assert.deepEqual([...doc.querySelectorAll('[role=tab]')].map(t => t.getAttribute('aria-selected')), ['true', 'false', 'false']);
  // jsdom does not execute iframe srcdoc. Hydrate the exact emitted document;
  // the source equality check prevents this harness from testing a substitute UI.
  frames.forEach((f, i) => {
    const expected = fs.readFileSync(path.join(dir, ['behaviour.html', 'skips.html', 'dataqc.html'][i]), 'utf8');
    assert.equal(f.getAttribute('srcdoc'), expected);
    f.contentWindow.TextDecoder = TextDecoder;
    f.contentWindow.TextEncoder = TextEncoder;
    f.contentDocument.open();
    f.contentDocument.write(expected);
    f.contentDocument.close();
    w.setupFrame(f);
  });
  assert.equal(errors.length, 0, errors.join('\n'));
  assert(frames.every(f => f.contentDocument.querySelector('#suite_embed_style')));
  assert.match(frames[0].contentDocument.querySelector('#suite_embed_style').textContent, /body>\.logobar,body>\.mast\{display:none/);
  const source = frames[0].contentDocument;
  ['c_resp', 'c_ws', 'c_fd', 'c_fv'].forEach(id => {
    const mirrored = doc.getElementById('suite_' + id);
    assert(mirrored, 'Missing persistent mirror ' + id);
    assert.equal(mirrored.value, source.getElementById(id).value);
    assert(source.getElementById(id).closest('.ctrl').classList.contains('suite-mirrored'));
    assert.equal(doc.querySelector('label[for="suite_' + id + '"]').control, mirrored);
  });
  const actor = [...source.getElementById('c_resp').options].find(o => o.value);
  assert(actor);
  change(doc.getElementById('suite_c_resp'), actor.value);
  assert.equal(source.getElementById('c_resp').value, actor.value);
  assert(source.getElementById('review_scope').textContent.includes(actor.value));
  change(doc.getElementById('suite_c_resp'), '');
  assert.equal(source.getElementById('c_resp').value, '');
  change(doc.getElementById('suite_c_fd'), 'region');
  change(doc.getElementById('suite_c_fv'), '1');
  assert.equal(source.getElementById('c_fv').value, '1');
  assert(source.getElementById('review_scope').textContent.includes('region = 1'));
  assert(frames[0].contentWindow.lastA.rows.every(r => r.f.region === '1'));
  change(doc.getElementById('suite_c_fv'), '2');
  assert(frames[0].contentWindow.lastA.rows.every(r => r.f.region === '2'));
  change(doc.getElementById('suite_c_fd'), '');
  assert.equal(source.getElementById('c_fv').value, '');
  w.sh(3);
  assert(doc.getElementById('suite_filters').hidden, 'Shared controls must be hidden for independent Data QC populations');
  assert.equal(doc.getElementById('p3').style.display, 'block');
  assert.equal(doc.getElementById('b3').getAttribute('aria-selected'), 'true');
  doc.getElementById('b3').dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
  assert.equal(doc.getElementById('p1').style.display, 'block');
  assert(!doc.getElementById('suite_filters').hidden);
  assert.equal(doc.activeElement.id, 'b1');
  doc.getElementById('b1').dispatchEvent(new w.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
  assert.equal(doc.getElementById('p2').style.display, 'block');
  assert.equal(doc.activeElement.id, 'b2');
  // Height algorithm must grow AND shrink. Stub geometry explicitly because
  // jsdom has no layout engine; these are algorithm tests, not pixel assertions.
  w.sh(1);
  const wrap = source.querySelector('.wrap');
  Object.defineProperty(wrap, 'offsetHeight', { configurable: true, value: 1200 });
  Object.defineProperty(wrap, 'offsetTop', { configurable: true, value: 0 });
  w.fitFrame(frames[0]);
  assert.equal(frames[0].style.height, '1224px');
  Object.defineProperty(wrap, 'offsetHeight', { configurable: true, value: 450 });
  w.fitFrame(frames[0]);
  assert.equal(frames[0].style.height, '474px');
  assert.equal(errors.length, 0, errors.join('\n'));
  console.log('Suite layout: 7 DOM groups passed (titles/roles, exact srcdoc, embed style, shared controls, independent QC scope, keyboard tabs, grow/shrink sizing).');
} finally {
  dom.window.close();
}
