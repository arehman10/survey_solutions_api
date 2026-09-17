'use strict';

/* Execute the exact standalone Skip/Removal browser engine from suso.ado. */
const fs = require('fs');
const path = require('path');

const ado = process.argv[2] || path.join(__dirname, '..', 'suso.ado');
const text = fs.readFileSync(ado, 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function logicalLines(source) {
  const out = [];
  let current = '';
  for (const raw of source.split(/\r?\n/)) {
    const continued = /\/\/\/\s*$/.test(raw);
    const piece = continued ? raw.replace(/\/\/\/\s*$/, '') : raw;
    current += (current ? ' ' : '') + piece;
    if (!continued) {
      out.push(current);
      current = '';
    }
  }
  if (current) out.push(current);
  return out;
}

const source = [];
let collecting = false;
for (const line of logicalLines(text)) {
  const begin = line.indexOf('`"');
  const end = line.lastIndexOf('"\'');
  if (begin < 0 || end < begin) continue;
  const payload = line.slice(begin + 2, end);
  if (payload.startsWith('var SKP={')) collecting = true;
  if (collecting) source.push(payload);
  if (collecting && payload.includes('module.exports=SKP')) break;
}
assert(source.length > 0, 'could not extract SKP engine');
const holder = {exports: {}};
new Function('module', source.join('\n'))(holder);
const SKP = holder.exports;

function one(overrides) {
  return Object.assign({
    ak: 'actor-a', an: 'Actor A', ws: 'Completed', wc: 'completed',
    gk: 'pattern-1', gl: 'Pattern 1', id: 'i1', t: 'C', q: 1,
    need: 0, re: 1, ev: 1, cp: 1, cev: 1, out: 0, tu: 0,
    card: '<div>synthetic</div>'
  }, overrides || {});
}

const cases = [
  one(),
  one({
    id: 'i2', ws: 'Approved by Supervisor', wc: 'approvebysup',
    gk: 'pattern-2', gl: 'Pattern 2', t: 'V', q: 2, need: 1,
    re: 0, ev: 2, cp: 0, cev: 0, out: 2
  }),
  one({
    ak: 'actor-b', an: 'Actor B', id: 'i3', ws: 'Approved by Headquarters',
    wc: 'approvebyhq', q: 3, re: 3, ev: 3, cp: 1, cev: 3, out: 0
  }),
  one({
    ak: 'actor-b', an: 'Actor B', id: 'i4', ws: 'Rejected by Supervisor',
    wc: 'rejectbysup', gk: 'pattern-3', gl: 'Pattern 3', t: 'V', q: 1,
    need: 1, re: 0, ev: 1, cp: 0, cev: 0, out: 1, tu: 1
  })
];

function conservation(stats, label) {
  assert(stats.ev === stats.cev + stats.out,
    label + ': raw events must equal compact plus outside');
  assert(stats.h >= stats.ch,
    label + ': compact histories cannot exceed raw histories');
}

const allRows = SKP.scope(cases, '', '');
const all = SKP.stats(allRows);
assert(allRows.length === 4, 'All status must retain all histories');
assert(all.h === 4 && all.ev === 7 && all.ch === 2 && all.cev === 4 && all.out === 3,
  'All cards must report exhaustive and compact totals separately');
assert(all.q === 7 && all.need === 2 && all.re === 4 && all.resolved === 2,
  'All final-state cards must remain conserved');
conservation(all, 'all');

const completed = SKP.scope(cases, '', 'Completed');
assert(completed.length === 1 && completed[0].id === 'i1',
  'exact displayed interview status must filter histories');
conservation(SKP.stats(completed), 'completed');

const completedClass = SKP.scope(cases, '', 'completed');
assert(completedClass.length === 1 && completedClass[0].id === 'i1',
  'exact normalized status class must filter histories');

const approved = SKP.scope(cases, '', 'APP');
const approvedStats = SKP.stats(approved);
assert(approved.length === 2 && approved.some(row => row.id === 'i2') &&
  approved.some(row => row.id === 'i3'),
  'APP must pool Supervisor- and Headquarters-approved statuses');
assert(approvedStats.h === 2 && approvedStats.ev === 5 && approvedStats.ch === 1 &&
  approvedStats.cev === 3 && approvedStats.out === 2 && approvedStats.need === 1,
  'APP cards must recompute from the approved subset');
conservation(approvedStats, 'approved');

const approvedSupervisor = SKP.scope(cases, '', 'approvebysup');
assert(approvedSupervisor.length === 1 && approvedSupervisor[0].id === 'i2',
  'exact normalized Supervisor-approved class must work');
const approvedHq = SKP.scope(cases, '', 'approvebyhq');
assert(approvedHq.length === 1 && approvedHq[0].id === 'i3',
  'exact normalized Headquarters-approved class must work');

const actorApproved = SKP.scope(cases, 'actor-a', 'APP');
const actorApprovedStats = SKP.stats(actorApproved);
assert(actorApproved.length === 1 && actorApproved[0].id === 'i2',
  'actor and status filters must intersect rather than overwrite each other');
assert(actorApprovedStats.ev === 2 && actorApprovedStats.cev === 0 &&
  actorApprovedStats.out === 2 && actorApprovedStats.need === 1,
  'actor-by-status headline cards must recompute exactly');
conservation(actorApprovedStats, 'actor-approved');

// Technical patterns and action groups must be built after status scope.
const approvedPatterns = SKP.patterns(approved);
assert(approvedPatterns.length === 2 &&
  approvedPatterns.reduce((sum, row) => sum + row.h, 0) === 2 &&
  approvedPatterns.reduce((sum, row) => sum + row.ev, 0) === 5,
  'technical summary must use the current status scope');
const approvedGroups = SKP.groups(approved);
assert(approvedGroups.length === 1 && approvedGroups[0].cases.length === 1 &&
  approvedGroups[0].need === 1,
  'action list must use the current status scope and omit resolved histories');
const actorApprovedGroups = SKP.groups(actorApproved);
assert(actorApprovedGroups.length === 1 && actorApprovedGroups[0].cases[0].id === 'i2',
  'actor-by-status action list must retain only the intersected case');

assert(SKP.scope(cases, 'actor-a', 'Rejected by Supervisor').length === 0,
  'actor-by-status filter must not leak another actor\'s rejected history');
assert(SKP.scope(cases, 'actor-b', 'APP').length === 1,
  'exact normalized actor key and APP status must intersect');

// Execute Behaviour's exact pure engine too.  The standalone and Behaviour
// tabs must use the same actor x current-status intersection and conservation
// definitions for headline cards, technical patterns and action rows.
const pSource = [];
let pCollecting = false;
for (const line of logicalLines(text)) {
  const begin = line.indexOf('`"');
  const end = line.lastIndexOf('"\'');
  if (begin < 0 || end < begin) continue;
  const payload = line.slice(begin + 2, end);
  if (payload.startsWith('var P = {')) pCollecting = true;
  if (pCollecting) pSource.push(payload);
  if (pCollecting && payload.includes('module.exports=P')) break;
}
assert(pSource.length > 0, 'could not extract Behaviour engine P');
const pHolder = {exports: {}};
new Function('module', pSource.join('\n'))(pHolder);
const P = pHolder.exports;

const behaviourCases = cases.map(row => ({
  a: row.an, k: row.ak, t: row.gk, id: row.id, n: row.ev, q: row.q,
  ra: row.re, ck: row.need, tier: row.t, ws: row.ws, wc: row.wc,
  cp: row.cp, tu: row.tu
}));
const behaviourAll = P.removalView(behaviourCases, '', '');
assert(behaviourAll.histories === 4 && behaviourAll.events === 7 &&
  behaviourAll.compactHistories === 2 && behaviourAll.compactEvents === 4 &&
  behaviourAll.outsideEvents === 3 && behaviourAll.timingUnknown === 1,
  'Behaviour All cards must conserve raw/compact/outside histories');
assert(behaviourAll.events === behaviourAll.compactEvents + behaviourAll.outsideEvents,
  'Behaviour All raw events must conserve');

const behaviourApproved = P.removalView(behaviourCases, '', 'APP');
assert(behaviourApproved.histories === 2 && behaviourApproved.events === 5 &&
  behaviourApproved.compactHistories === 1 && behaviourApproved.compactEvents === 3 &&
  behaviourApproved.outsideEvents === 2 && behaviourApproved.check === 1,
  'Behaviour APP cards must pool only Supervisor/HQ approvals');
assert(behaviourApproved.patterns.length === 2 &&
  behaviourApproved.patterns.reduce((sum, row) => sum + row.h, 0) === 2 &&
  behaviourApproved.patterns.reduce((sum, row) => sum + row.n, 0) === 5 &&
  behaviourApproved.patterns.reduce((sum, row) => sum + row.cn, 0) === 3 &&
  behaviourApproved.patterns.reduce((sum, row) => sum + row.out, 0) === 2,
  'Behaviour technical patterns must recompute after APP status scope');

const behaviourExact = P.removalView(
  behaviourCases, '', 'Approved by Supervisor');
assert(behaviourExact.histories === 1 && behaviourExact.rows[0].id === 'i2',
  'Behaviour exact current-status scope must work');
const behaviourActorApproved = P.removalView(
  behaviourCases, ' Actor-A ', 'APP');
assert(behaviourActorApproved.histories === 1 &&
  behaviourActorApproved.rows[0].id === 'i2' &&
  behaviourActorApproved.events === 2 && behaviourActorApproved.outsideEvents === 2 &&
  behaviourActorApproved.active === 1 && behaviourActorApproved.resolved === 0,
  'Behaviour actor x APP cards/action rows must use the intersection');
assert(P.removalView(behaviourCases, 'actor-a', 'Rejected by Supervisor').histories === 0,
  'Behaviour actor x status scope must not leak another actor history');

console.log('PASS removal_inventory_engine_regression.js');
