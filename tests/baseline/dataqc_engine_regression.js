'use strict';

/* Execute the pure Data-QC dashboard engine emitted by suso.ado. */
const fs = require('fs');
const path = require('path');

const ado = process.argv[2] || path.join(__dirname, '..', 'suso.ado');
const adoText = fs.readFileSync(ado, 'utf8');
const lines = adoText.split(/\r?\n/);
let collecting = false;
const source = [];
for (const line of lines) {
  const begin = line.indexOf('`"');
  const end = line.lastIndexOf('"\'');
  if (begin < 0 || end < begin) continue;
  const text = line.slice(begin + 2, end);
  if (text.startsWith('var C = {')) collecting = true;
  if (collecting) source.push(text);
  if (collecting && text.includes('module.exports=C')) break;
}
if (!source.length) throw new Error('could not extract Data-QC engine C from ' + ado);
const holder = {exports: {}};
new Function('module', source.join('\n'))(holder);
const C = holder.exports;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// The verdict describes the same population used by deriveF(), and the status
// and final-data breakdowns are deliberately alternatives. Pin the emitted UI
// handlers as well as the pure aggregation engine so a dashboard-only edit
// cannot silently show a filtered number with an all/status scope label.
assert(adoText.includes(
  "var scope = (S.fd&&S.fv) ? ('filter '+S.fd+' = '+S.fv)"),
  'Data-QC verdict must name the active final-data filter dimension and value');
assert(adoText.includes(
  "el('c_fd').addEventListener('change',function(){ fvOptions(); if(el('c_fd').value) el('c_ist').value=''; renderAll(); });"),
  'choosing a final-data filter dimension must clear the status breakdown');
assert(adoText.includes(
  "el('c_ist').addEventListener('change',function(){ if(el('c_ist').value){ el('c_fd').value=''; fvOptions(); } renderAll(); });"),
  'choosing a status breakdown must clear and reset the final-data filter');

// A has an answered question whose gate is undetermined; B is clean. Status and
// final-data filters must recompute vu from their own vectors rather than retain
// the all-record value of one.
const question = {
  v: 'child', st: 'evaluated', s: 'Section', t: 'Text', q: 'Child?', e: 'gate==1',
  bv: '', on: 1, und: 1, vu: 1, vi: 0, im: 0, bd: 0, sh: 0,
  ons: [0, 1], uns: [1, 0], vus: [1, 0], vis: [0, 0], ims: [0, 0], bds: [0, 0],
  fv: {stratum: {
    A: [0, 1, 1, 0, 0, 0],
    B: [1, 0, 0, 0, 0, 0]
  }}
};
const meta = {
  statuses: [{c: 100, l: 'Completed', n: 1}, {c: 130, l: 'Approved by HQ', n: 1}],
  fdims: [{v: 'stratum', vals: [{c: 'A', n: 1}, {c: 'B', n: 1}]}]
};

const statusA = C.derive([question], meta, '0')[0];
const statusB = C.derive([question], meta, '1')[0];
assert(statusA.vu === 1 && statusA.und === 1,
  'status A must retain its one undetermined-with-answer case');
assert(statusB.vu === 0 && statusB.und === 0,
  'status B must not inherit the global undetermined-with-answer count');
assert(C.kpis([statusA]).vu === 1 && C.kpis([statusB]).vu === 0,
  'status-filter KPI must use the recomputed vu vector');

const filterA = C.deriveF([question], 'stratum', 'A')[0];
const filterB = C.deriveF([question], 'stratum', 'B')[0];
assert(filterA.vu === 1 && filterA.und === 1,
  'filter A must retain its one undetermined-with-answer case');
assert(filterB.vu === 0 && filterB.und === 0,
  'filter B must not inherit the global undetermined-with-answer count');
assert(filterB.vi === 0 && filterB.im === 0 && filterB.bd === 0,
  'six-slot filter vector mapping must preserve the other Data-QC measures');

// Exercise the documented maximum of 40 filter values (two dimensions x 20),
// including a JSON round trip matching the self-contained HTML payload. Every
// six-slot vector must remain independently addressable at the budget boundary.
const budgetQuestion = Object.assign({}, question, {fv: {}});
const budgetMeta = {statuses: meta.statuses, fdims: []};
for (let dim = 0; dim < 2; dim++) {
  const name = 'dimension_' + dim;
  const values = [];
  budgetQuestion.fv[name] = {};
  for (let value = 0; value < 20; value++) {
    const code = String(dim * 20 + value);
    const vu = value % 3 === 0 ? 1 : 0;
    values.push({c: code, l: 'Value ' + code, n: 2});
    budgetQuestion.fv[name][code] = [2 - vu, vu, vu, 0, 0, 0];
  }
  budgetMeta.fdims.push({v: name, vals: values});
}
const budgetPayload = JSON.parse(JSON.stringify({
  meta: budgetMeta, rows: [budgetQuestion]
}));
assert(budgetPayload.meta.fdims.reduce((n, dim) => n + dim.vals.length, 0) === 40,
  'max-budget Data-QC JSON must retain all 40 advertised filter values');
for (const dim of budgetPayload.meta.fdims) {
  for (const value of dim.vals) {
    const cell = C.deriveF(budgetPayload.rows, dim.v, value.c)[0];
    const expected = Number(value.c) % 20 % 3 === 0 ? 1 : 0;
    assert(cell.vu === expected && cell.und === expected,
      'max-budget filter value ' + dim.v + '=' + value.c + ' mapped the wrong vector');
  }
}

// "Fieldwork done" is a workflow subset, not every numeric status >=65.
// ReadyForInterview, SentToCapi, and Restarted have not completed fieldwork and
// must not inflate enabled-but-unanswered counts in the default dashboard view.
const fieldCodes = [65, 80, 85, 95, 100, 120, 125, 130];
const fieldMeta = {
  statuses: fieldCodes.map(code => ({c: code, l: String(code), n: 1})),
  fdims: []
};
const fieldQuestion = Object.assign({}, question, {
  on: fieldCodes.reduce((sum, code) => sum + code, 0),
  und: 0, vu: 0, vi: 0, im: 0, bd: 0,
  ons: fieldCodes.slice(), uns: fieldCodes.map(() => 0),
  vus: fieldCodes.map(() => 0), vis: fieldCodes.map(() => 0),
  ims: fieldCodes.map(() => 0), bds: fieldCodes.map(() => 0)
});
const fieldDerived = C.derive([fieldQuestion], fieldMeta, 'FIELD')[0];
assert(fieldDerived.on === 65 + 100 + 120 + 125 + 130,
  'FIELD derive must include exactly 65/100/120/125/130');
assert(C.recs(fieldMeta, 'FIELD') === 5,
  'FIELD record count must exclude ReadyForInterview/SentToCapi/Restarted');


/* ---- v1.7.26 SUITETRIAGE: triage sections on the Data QC page ---- */
assert(adoText.includes('function updateDqSections(K,scope){'),
  'Data QC must drive a live section-status engine');
assert(adoText.includes('  updateDqSections(K,scope);'),
  'sections must be updated from the same K totals as the verdict and badge');
assert(adoText.includes('  initDqSections();'),
  'section wiring must install once before the first render');
assert(adoText.includes("secOpen('s_list',true); }"),
  'only the Questions browser opens by default');
assert(!adoText.includes("el('sec_viol').style.display") &&
       !adoText.includes("el('sec_bad').style.display") &&
       !adoText.includes("el('sec_vund').style.display"),
  'clean hard sections must stay visible as green checks, never hidden');
assert(adoText.split("None in this view.").length - 1 === 3,
  'each empty hard chart must state its emptiness');

console.log('PASS dataqc_engine_regression.js');
