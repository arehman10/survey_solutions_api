'use strict';

/* suso v1.7.26 SUITETRIAGE - offline regression for the suite shell script.
 *
 * Extracts the plain-string fwrite() JavaScript between <script> and
 * </script> in _suso_suite_write (the tabbed suite shell), executes it
 * against a faked document/window with three iframe panes, and verifies:
 *   - tab badges: valid 'suso-tab-badge' messages from a pane's own iframe
 *     update that tab's badge text/class via textContent and rebuild the
 *     digest line with correct singular/plural grammar;
 *   - validation: badge messages with a non-number n, out-of-range n, an
 *     unknown severity, or a foreign source are ignored;
 *   - the pre-existing actor/status filter relay still forwards between
 *     panes 1 and 2 only, and badge traffic never triggers the relay.
 */

const fs = require('fs');
const path = require('path');

const ado = process.argv[2] || path.join(__dirname, '..', 'suso.ado');
const adoText = fs.readFileSync(ado, 'utf8');

function assert(cond, msg) { if (!cond) throw new Error(msg); }

// ---- extract the shell <script> body from the Mata writer ------------------
const lines = adoText.split(/\r?\n/);
const src = [];
let inShell = false, inScript = false;
for (const line of lines) {
  if (line.includes('void _suso_suite_write(')) inShell = true;
  if (!inShell) continue;
  const m = line.match(/^\s*fwrite\(fh, "(.*)" \+ char\(10\)\)\s*$/) ||
    line.match(/^\s*fwrite\(fh, `"(.*)"' \+ char\(10\)\)\s*$/);
  if (!m) continue;
  const text = m[1];
  if (text === '<script>') { inScript = true; continue; }
  if (text.startsWith('</script>')) break;
  if (inScript) src.push(text);
}
assert(src.length >= 6, 'could not extract the suite shell script body');
const shellJs = src.join('\n');
assert(shellJs.includes("'suso-tab-badge'"), 'shell must handle suso-tab-badge');
assert(shellJs.includes("'#p1 iframe,#p2 iframe,#p3 iframe'"),
  'badge listener must consider all three panes');

// ---- fake DOM --------------------------------------------------------------
function fakeNode(id) {
  return {
    id, className: '', textContent: '', style: {},
    listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; },
  };
}
const nodes = {};
function el(id) { return nodes[id] || (nodes[id] = fakeNode(id)); }

const iframes = {};
for (let k = 1; k <= 3; k++) {
  const pane = el('p' + k);
  iframes[k] = {
    parentNode: pane,
    sent: [],
    contentWindow: { postMessage(msg) { iframes[k].sent.push(msg); } },
    listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
  };
}
function selectIframes(sel) {
  if (sel === '.pane iframe') return [iframes[1], iframes[2], iframes[3]];
  const out = [];
  for (const part of String(sel).split(',')) {
    const m = part.trim().match(/^#p([123]) iframe$/);
    if (m) out.push(iframes[+m[1]]);
  }
  return out;
}
const documentFake = {
  getElementById: el,
  querySelector(sel) { return sel === '.tabs' ? el('tabs') : (selectIframes(sel)[0] || null); },
  querySelectorAll: selectIframes,
};
const messageHandlers = [];
const windowFake = {
  addEventListener(type, fn) { if (type === 'message') messageHandlers.push(fn); },
};

new Function('document', 'window', shellJs)(documentFake, windowFake);
assert(messageHandlers.length === 3,
  'shell must install badge, filter-relay and removal-navigation listeners');

function fire(source, data) { for (const h of messageHandlers) h({ data, source }); }
const w1 = iframes[1].contentWindow, w2 = iframes[2].contentWindow, w3 = iframes[3].contentWindow;

// ---- badge behaviour -------------------------------------------------------
fire(w1, { type: 'suso-tab-badge', n: 5, sev: 'b' });
assert(el('tbad1').textContent === '5', 'tab-1 badge text');
assert(el('tbad1').className === 'tbadge on b', 'tab-1 badge class');
assert(el('sdigest').textContent === '5 interviews need attention', 'digest after tab 1');

fire(w2, { type: 'suso-tab-badge', n: 0, sev: 'g' });
assert(el('tbad2').textContent === '\u2713', 'zero badge renders a check');
assert(el('tbad2').className === 'tbadge on g', 'zero badge is green');
assert(el('sdigest').textContent === '5 interviews need attention - removals resolved',
  'digest joins tabs in order');

fire(w3, { type: 'suso-tab-badge', n: 2, sev: 'b' });
assert(el('sdigest').textContent ===
  '5 interviews need attention - removals resolved - Data QC: 2 hard problems',
  'digest includes Data QC');

fire(w1, { type: 'suso-tab-badge', n: 1, sev: 'w' });
assert(el('tbad1').className === 'tbadge on w', 'badge severity updates');
assert(el('sdigest').textContent ===
  '1 interview needs attention - removals resolved - Data QC: 2 hard problems',
  'singular grammar: 1 interview needs attention');

fire(w3, { type: 'suso-tab-badge', n: 1, sev: 'b' });
assert(el('sdigest').textContent.endsWith('Data QC: 1 hard problem'),
  'singular grammar: 1 hard problem');
fire(w2, { type: 'suso-tab-badge', n: 1, sev: 'w' });
assert(el('sdigest').textContent.includes('1 removal check open'),
  'singular grammar: 1 removal check open');

fire(w1, { type: 'suso-tab-badge', n: 1234567, sev: 'w' });
assert(el('tbad1').textContent === (1234567).toLocaleString(),
  'large badge counts are locale-formatted');

// ---- validation ------------------------------------------------------------
const before1 = el('tbad1').textContent, beforeD = el('sdigest').textContent;
fire(w1, { type: 'suso-tab-badge', n: '7', sev: 'b' });
fire(w1, { type: 'suso-tab-badge', n: NaN, sev: 'b' });
fire(w1, { type: 'suso-tab-badge', n: -1, sev: 'b' });
fire(w1, { type: 'suso-tab-badge', n: 10000000, sev: 'b' });
fire(w1, { type: 'suso-tab-badge', n: 3, sev: 'x' });
fire({ postMessage() {} }, { type: 'suso-tab-badge', n: 3, sev: 'b' });
assert(el('tbad1').textContent === before1 && el('sdigest').textContent === beforeD,
  'invalid or foreign badge messages must be ignored');

// ---- filter relay unchanged ------------------------------------------------
iframes[1].sent.length = iframes[2].sent.length = iframes[3].sent.length = 0;
fire(w1, { type: 'suso-actor-filter', key: 'anna', label: 'Anna' });
assert(iframes[2].sent.length === 1 && iframes[2].sent[0].key === 'anna',
  'actor filter from pane 1 must reach pane 2');
assert(iframes[1].sent.length === 0, 'filter must not echo to its source');
assert(iframes[3].sent.length === 0, 'filter relay must exclude Data QC');

iframes[2].sent.length = 0;
fire(w2, { type: 'suso-status-filter', key: 'Completed' });
assert(iframes[1].sent.length === 2 &&
       iframes[1].sent[0].type === 'suso-actor-filter' &&
       iframes[1].sent[1].key === 'Completed',
  'status filter from pane 2 must reach pane 1 with the stored actor filter');

iframes[1].sent.length = iframes[2].sent.length = 0;
fire(w1, { type: 'suso-tab-badge', n: 2, sev: 'w' });
assert(iframes[1].sent.length === 0 && iframes[2].sent.length === 0 &&
       iframes[3].sent.length === 0,
  'badge traffic must never trigger the filter relay');

fire(w1, { type: 'suso-actor-filter', key: 'x'.repeat(501), label: 'x' });
assert(iframes[2].sent.length === 0, 'oversize filter keys are still rejected');

console.log('PASS suite_shell_regression.js');
