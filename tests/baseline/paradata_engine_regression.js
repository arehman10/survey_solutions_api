'use strict';

/* Offline regression for the pure JavaScript engine embedded by suso.ado. */
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
  if (text.startsWith('var P = {')) collecting = true;
  if (collecting) source.push(text);
  if (collecting && text.includes('module.exports=P')) break;
}
if (!source.length) throw new Error('could not extract paradata engine P from ' + ado);
if (!adoText.includes("data-t='+Q+attr(r.id)+Q"))
  throw new Error('interview copy data-t must use the attribute escaper');
if (!adoText.includes("data-t='+Q+attr(r.k)+Q"))
  throw new Error('key copy data-t must use the attribute escaper');
if (!adoText.includes('else if (c==60) out = out + "\\u003C"'))
  throw new Error('JSON escape must neutralize a closing-script opener');
if (!adoText.includes('src=P.questionRows(D.q,qActorIndex,resp,ws)'))
  throw new Error('Question timing DOM must intersect actor and status selectors');
if (!adoText.includes('var k=rows.length') || adoText.includes('Math.min(rows.length,40)'))
  throw new Error('Question timing must render every observed matching question');
if (!adoText.includes('answer events</th>') || !adoText.includes('timed reaches</th>'))
  throw new Error('Question timing must expose event and timing denominators');
if (!adoText.includes("window.parent.postMessage({type:'suso-actor-filter',key:P.norm(value),label:label},'*')"))
  throw new Error('Behaviour actor changes must notify the suite parent');
if (!adoText.includes("window.parent===window||ev.source!==window.parent||typeof d.key!=='string'"))
  throw new Error('Behaviour report must accept filter sync only from its parent');
if (!adoText.includes("d.type==='suso-actor-filter'") ||
    !adoText.includes("d.type==='suso-status-filter'"))
  throw new Error('Behaviour report must handle both actor and status synchronization');
if (!adoText.includes("o.textContent=(d.label||d.key)+' (0 timing rows)'"))
  throw new Error('Behaviour must retain a Skip-only actor as an explicit zero-timing selection');
if (adoText.includes('sel.value=value; renderAll(); postActorFilter();'))
  throw new Error('parent-applied actor sync must not be reposted');
const holder = {exports: {}};
new Function('module', source.join('\n'))(holder);
const P = holder.exports;

// Compile the browser-only layer as well. It is emitted entirely as literal
// JavaScript lines after P; Node has no document, so executing the wrapper is a
// syntax check without attempting to render the report.
const domSource = [];
let domCollecting = false;
for (const line of lines) {
  const begin = line.indexOf('`"');
  const end = line.lastIndexOf('"\'');
  if (begin < 0 || end < begin) continue;
  const text = line.slice(begin + 2, end);
  if (text.startsWith('/* ---------------- DOM layer')) domCollecting = true;
  if (!domCollecting) continue;
  if (text.startsWith('</script>')) break;
  domSource.push(text);
}
if (!domSource.length) throw new Error('could not extract browser DOM layer');
new Function('P', 'D', domSource.join('\n'))(P, {});

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function close(actual, expected, tolerance, message) {
  assert(Math.abs(actual - expected) <= tolerance,
    message + ': got ' + actual + ', expected ' + expected);
}
function settings() {
  return Object.assign({fs: 2, top: 25}, P.presets.standard);
}
function baseRow(overrides) {
  return Object.assign({
    id: 'case-1', k: '11-22-33-44', a: '101', r: 'Primary Tester',
    le: 'Primary Tester', fi: 'Primary Tester', na: 1, ho: 0, pas: 1,
    ws: 'Completed', wsp: 'Completed', wsd: '', wss: 'paradata',
    wsc: 'completed', wsm: 0, d0: '2026-07-14', d1: '2026-07-14',
    m: 0, mm: 0, mu: 0, tq: 1, lq: 1,
    itq: 1, ilq: 1, im: 0, imm: 0, imu: 0,
    ito: 0, cb: 0, nt: 30, ntt: 30, nc: 1,
    act: 12, af: 12, paf: 12, pact: 12, sp: 12, spf: 12,
    lp: 0, lpp: 0, wd: 1, wdt: 1,
    on: 0, pr: 0, med: 4, fsh: 0.1, nsh: 0, ch: 0, cas: 0,
    rem: 0, wip: 0, cop: 0, cr: 0, cu: 0, fda: 0, fad: 0, feb: 0,
    fbe: 0, flu: 0, fnd: 0, fck: 0, fdc: 0, fr: 1, rt: 1,
    ov: 0, ovt: 0, ova: '', ovd: '', rj: 0, rb: null, rq: null,
    re: null, ref: null, rba: '', rbv: '', rbc: 0, rbb: 0,
    pc: 0, pca: 0, pcn: 0, pco: 0, pcf: 0, pcno: 0, pcd: '', ve: 0,
    nq: 30, pq: 30, pans: 30, pansf: 30, pss: 1,
    ss: 1, sf: 1, sr: 0, rs: 0, tz: 5.5, to: 0
  }, overrides || {});
}
function evaluate(row, S, contextRows) {
  const rows = contextRows || [row];
  const out = P.aggregate([row], S, P.zctx(rows));
  return out.flagged.length ? out.flagged[0] : row;
}
function csvColumns(line) {
  let count = 1;
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    if (line[i] === '"') {
      if (quoted && line[i + 1] === '"') i++;
      else quoted = !quoted;
    } else if (line[i] === ',' && !quoted) count++;
  }
  return count;
}
function parseCsvLine(line) {
  const out = [];
  let value = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') {
      if (quoted && line[i + 1] === '"') { value += '"'; i++; }
      else quoted = !quoted;
    } else if (c === ',' && !quoted) { out.push(value); value = ''; }
    else value += c;
  }
  out.push(value);
  return out;
}
function parseCSV(text) {
  const rows = [];
  let record = [];
  let value = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { value += '"'; i++; }
      else if (c === '"') quoted = false;
      else value += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') { record.push(value); value = ''; }
    else if (c === '\n' || c === '\r') {
      record.push(value);
      rows.push(record);
      record = [];
      value = '';
      if (c === '\r' && text[i + 1] === '\n') i++;
    } else value += c;
  }
  record.push(value);
  rows.push(record);
  return rows;
}

const S = settings();
assert(S.minact === 5, 'Standard first-pass active-time floor must be five minutes');
assert(P.presets.lenient.minact < S.minact && P.presets.strict.minact > S.minact,
  'Sensitivity presets must be monotonic');

// Domain grouping: correlated speed and duration measures do not masquerade as
// independent evidence.
function tierFor(indices, extra) {
  const row = baseRow(extra);
  row._f = Array.from({length: 8}, (_, i) => indices.indexOf(i) >= 0);
  row._n = row._f.filter(Boolean).length;
  row._r = P.resub(row);
  row._d = P.domains(row);
  return P.tierFor(row);
}
assert(tierFor([0]) === 'W', 'S alone should be Watch');
assert(tierFor([0, 1]) === 'V', 'S+B should be Verify');
assert(tierFor([0, 1, 2]) === 'V', 'S+B+T should remain Verify');
assert(tierFor([0, 1, 2, 3]) === 'A', 'three independent domains should Investigate');
assert(tierFor([7]) === 'V', 'shared-minute screen alone should be Verify, not proof');
assert(tierFor([], {on: 1}) === 'W', 'next-day continuation alone should be Watch');
assert(tierFor([], {rj: 1, rbc: 1, rq: 0, re: 0}) === 'A',
  'unchanged rejection/re-completion should Investigate');
assert(tierFor([], {rj: 1, rbc: 1, rq: 2, re: 3, rb: 5}) === 'V',
  'quick two-question correction cycle should Verify');
assert(tierFor([], {rj: 1, rbc: 1, rq: null, re: 3, rb: 5}) === 'V',
  'edited reduced-schema correction should Verify as unknown, not look unchanged');
assert(tierFor([], {wsm: 1}) === 'V', 'status mismatch should be visible as Verify');
const restarted = baseRow({ws: 'Restarted', wsp: 'Restarted', wsc: 'inprogress'});
assert(P.filterRows([restarted], '', 'Restarted', '', '', []).length === 1,
  'canonical Restarted status must remain selectable without a mismatch');

// The supplied overnight pattern: active time excludes the 22-hour pause, but the
// continuation remains visible. At the five-minute floor it is S+B, not T.
const overnight = evaluate(baseRow({
  id: 'overnight', med: 1.545, fsh: 76 / 116, fr: 13, nt: 116,
  act: 5.68545, af: 5.68545, sp: 1359.477, lp: 1353.792,
  lpp: 1353.792, wd: 2, on: 1, d1: '2026-07-15', ss: 2, sf: 2
}), S);
assert(overnight._f[0] && overnight._f[1], 'overnight case should retain S and B');
assert(!overnight._f[2], '5.685 active minutes must not trigger T at five minutes');
assert(overnight._t === 'V', 'overnight S+B should be Verify');

// Actor handoff and rejection correction: first-pass behavior belongs to the
// primary contributor, while the correction actor stays separate.
const handoff = evaluate(baseRow({
  id: 'handoff', r: 'Primary Tester', le: 'Correction Tester', na: 2, ho: 1,
  pas: 125 / 127, med: 1.630, fsh: 63 / 109, fr: 12, nt: 109, ntt: 111,
  pans: 125, pansf: 125, pact: 6.6319667,
  act: 6.6319667, af: 6.1969167, paf: 6.1969167, ss: 3, sf: 2, sr: 1,
  pr: 1, rj: 1, rb: 5.010583, rq: 2, re: 3, rbc: 1,
  rba: 'Correction Tester', rbv: 'q30; q6', ov: 0
}), S);
assert(handoff._f[0] && handoff._f[1] && !handoff._f[2],
  'handoff case should be S+B without T');
assert(P.softResub(handoff) && !P.resub(handoff),
  'two distinct questions / three edit events must be a soft, not unchanged, resubmission');
assert(handoff._t === 'V', 'handoff case should be Verify');
const evidence = P.evidence(handoff, S, P.team([handoff]), {fastsecs: 2, tzmode: 5.5})
  .map(x => x.s).join(' | ');
assert(evidence.includes('Primary Tester') && evidence.includes('Correction Tester'),
  'evidence must identify both primary and correction actors');
assert(evidence.includes('2 distinct question(s)') && evidence.includes('3 edit event(s)'),
  'evidence must distinguish questions from raw edit events');

// Actor league is built from actor rows. The correction actor cannot inherit the
// primary actor's speed/streak flags.
const actorRows = [
  {id: 'handoff', r: 'Primary Tester', p: 1, f: 1, l: 0, ans: 125, ansf: 125,
    share: 125 / 127, act: 6.63, af: 6.20, q: 105, ss: 2,
    nt: 109, med: 1.630, fsh: 63 / 109, nsh: 0, ch: 0.02,
    rt: 0.3, fr: 12, ov: 0, tq: 1, lq: 1, m: 0, mm: 0,
    tz: 5.5, to: 0, h: null, g: null, ovd: ''},
  {id: 'handoff', r: 'Correction Tester', p: 0, f: 0, l: 1, ans: 2, ansf: 0,
    share: 2 / 127, act: 0.44, af: 0, q: 2, ss: 1, nt: 0, med: null,
    fsh: null, nsh: null, ch: 0, rt: null, fr: 0, ov: 0,
    tq: 1, lq: 1, m: 0, mm: 0, tz: null, to: 0,
    h: null, g: null, ovd: ''}
];
const handoffNoWorkflow = Object.assign({}, handoff,
  {rj: 0, rb: null, rq: null, re: null, rba: '', rbv: '', rbc: 0});
const league = P.league([handoffNoWorkflow], actorRows, S);
const primaryLeague = league.find(x => x.r === 'Primary Tester');
const correctionLeague = league.find(x => x.r === 'Correction Tester');
assert(primaryLeague && primaryLeague.fl === 1, 'primary actor should own the behavior flag');
assert(correctionLeague && correctionLeague.fl === 0,
  'correction actor must not inherit primary behavior');
assert(P.filterRows([handoff], 'Correction Tester', '', '', '', actorRows).length === 1,
  'any-actor filter should include a correction-only contribution');
const correctionView = P.filterRows([handoff], 'Correction Tester', '', '', '', actorRows)[0];
const correctionFlags = P.flagsFor(correctionView, S, null);
assert(!correctionFlags[0] && !correctionFlags[1] && !correctionFlags[2] &&
  !correctionFlags[5] && !correctionFlags[6],
  'correction-only actor must not inherit primary S/B/T/Z/P signals');
assert(correctionView.r === 'Primary Tester' && correctionView.vr === 'Correction Tester',
  'actor projection must preserve the primary owner and expose metric_actor separately');
assert(P.league([handoff], actorRows, S, 'Correction Tester').length === 1 &&
  P.league([handoff], actorRows, S, 'Correction Tester')[0].r === 'Correction Tester',
  'actor-filtered league must contain only the selected contributor');

// Question timing intersects actor ownership with current/final interview status.
// Empty actor/status combinations are explicit empties, never a fallback. The
// timed-reach count is the denominator for median/p90/fast share.
const teamQuestions = [
  {s: '', v: 'q1', n: 30, ni: 20, nt: 18, med: 4, p90: 9, fsh: 0.10},
  {s: '', v: 'q2', n: 25, ni: 18, nt: 15, med: 6, p90: 12, fsh: 0.05},
  {s: 'Completed', v: 'q1', n: 10, ni: 8, nt: 7, med: 5, p90: 10, fsh: 0.05},
  {s: 'Approved by Sup', v: 'q1', n: 7, ni: 6, nt: 6, med: 3, p90: 7, fsh: 0.20},
  {s: 'Approved by HQ', v: 'q1', n: 13, ni: 6, nt: 5, med: 2, p90: 6, fsh: 0.30},
  {s: 'APP', v: 'q1', n: 20, ni: 12, nt: 11, med: 2.5, p90: 6.5, fsh: 0.25}
];
const actorQuestions = [
  {r: 'Primary Tester', k: 'primary tester', s: '', v: 'q1', n: 12, ni: 9,
    nt: 8, med: 2, p90: 5, fsh: 0.40},
  {r: 'Primary Tester', k: 'primary tester', s: '', v: 'q2', n: 8, ni: 7,
    nt: 6, med: 3, p90: 6, fsh: 0.25},
  {r: 'Primary Tester', k: 'primary tester', s: 'Completed', v: 'q1', n: 5, ni: 4,
    nt: 3, med: 4, p90: 8, fsh: 0.10},
  {r: 'Primary Tester', k: 'primary tester', s: 'APP', v: 'q1', n: 7, ni: 5,
    nt: 5, med: 1.5, p90: 4, fsh: 0.60},
  {r: '__proto__', k: '__proto__', s: '', v: 'q1', n: 2, ni: 2,
    nt: 2, med: 7, p90: 8, fsh: 0},
  {r: "ÅCTOR O'Neil <HQ>", k: "åctor o'neil <hq>", s: '', v: 'q3', n: 1, ni: 1,
    nt: 1, med: 11, p90: 11, fsh: 0}
];
const questionIndex = P.questionIndex(actorQuestions);
const allQuestions = P.questionRows(teamQuestions, questionIndex, '', '');
assert(allQuestions.length === 2 && allQuestions[0].nt === 18,
  'All enumerators/all statuses must select the exact survey-wide scope');
const completedQuestions = P.questionRows(teamQuestions, questionIndex, '', 'Completed');
assert(completedQuestions.length === 1 && completedQuestions[0].n === 10 &&
  completedQuestions[0].ni === 8 && completedQuestions[0].nt === 7,
  'exact status scope must retain separate event/interview/timed denominators');
const approvedQuestions = P.questionRows(teamQuestions, questionIndex, '', 'APP');
assert(approvedQuestions.length === 1 && approvedQuestions[0].n === 20 &&
  approvedQuestions[0].med === 2.5,
  'Approved only must use its exact pre-aggregated Sup+HQ population');
const primaryQuestions = P.questionRows(teamQuestions, questionIndex, ' PRIMARY TESTER ', '');
assert(primaryQuestions.length === 2 && primaryQuestions[0].med === 2 &&
  primaryQuestions[1].med === 3,
  'selected actor must use only their actor-question aggregates');
const primaryCompleted = P.questionRows(teamQuestions, questionIndex,
  'Primary Tester', 'Completed');
assert(primaryCompleted.length === 1 && primaryCompleted[0].n === 5 &&
  primaryCompleted[0].nt === 3,
  'selected actor and status must be intersected exactly');
assert(P.questionRows(teamQuestions, questionIndex, 'Primary Tester', 'Rejected by HQ').length === 0,
  'empty actor/status intersection must not fall back to another scope');
assert(P.questionRows(teamQuestions, questionIndex, 'Correction Tester', '').length === 0,
  'correction-only actor must show an empty question table, not inherit D.q');
assert(P.questionRows(teamQuestions, questionIndex, '__proto__', '').length === 1 &&
  P.questionRows(teamQuestions, questionIndex, '__proto__', '')[0].med === 7,
  'prototype-like actor keys must survive question-index grouping');
assert(P.questionRows(teamQuestions, questionIndex, " åctor o'NEIL <hq> ", '').length === 1,
  'Unicode, quotes and HTML characters must survive normalized actor lookup');
const qPerfRows = [];
for (let actorNo = 0; actorNo < 200; actorNo++) {
  for (const scope of ['', 'Completed', 'APP']) {
    for (let questionNo = 0; questionNo < 250; questionNo++) {
      qPerfRows.push({r: 'Actor ' + actorNo, k: 'actor ' + actorNo, s: scope,
        v: 'q' + questionNo, n: 1, ni: 1, nt: 1, med: 4, p90: 8, fsh: 0});
    }
  }
}
const qPerfStart = Date.now();
const qPerfIndex = P.questionIndex(qPerfRows);
const qPerfSelected = P.questionRows(teamQuestions, qPerfIndex, 'Actor 137', 'APP');
const qPerfElapsed = Date.now() - qPerfStart;
assert(qPerfSelected.length === 250,
  'actor/status question index must return only the selected intersection');
assert(qPerfElapsed < 5000,
  '150,000 actor/status/question cells must index/select under 5 seconds; got ' + qPerfElapsed + ' ms');

// Behaviour's technical removal-pattern table and its action-list count use
// the same actual removal-run actor scope as the standalone Skip page.
const behaviorRemovals = [
  {a: 'Enumerator A', k: 'enumerator a', t: 'gate_a', id: 'i1', n: 3, q: 2,
    ra: 1, ck: 1, tier: 'V'},
  {a: 'Enumerator A', k: 'enumerator a', t: 'gate_a', id: 'i2', n: 4, q: 3,
    ra: 3, ck: 0, tier: 'C'},
  {a: 'Correction B', k: 'correction b', t: 'gate_b', id: 'i1', n: 5, q: 4,
    ra: 0, ck: 2, tier: 'A'},
  {a: '__proto__', k: '__proto__', t: '__proto__', id: '__proto__', n: 2, q: 1,
    ra: 0, ck: 1, tier: 'V'}
];
const allRemovalView = P.removalView(behaviorRemovals, '');
assert(allRemovalView.histories === 4 && allRemovalView.events === 14 &&
  allRemovalView.active === 3 && allRemovalView.resolved === 1,
  'all-actor Behaviour removal totals must preserve every compact run');
const correctionRemovalView = P.removalView(behaviorRemovals, ' CORRECTION B ');
assert(correctionRemovalView.histories === 1 && correctionRemovalView.events === 5 &&
  correctionRemovalView.check === 2 && correctionRemovalView.patterns[0].v === 'gate_b',
  'Behaviour removal summary must recompute from the selected run actor');
assert(P.removalView(behaviorRemovals, 'Primary Owner').histories === 0,
  'interview ownership must not inherit another actor\'s removal run');
assert(P.removalView(behaviorRemovals, '__proto__').patterns.length === 1,
  'prototype-like actor and pattern keys must survive Behaviour removal grouping');

// JavaScript prototype names are legitimate Survey Solutions login strings.
// Null-prototype grouping maps must preserve them as ordinary data keys.
const prototypeNames = ['__proto__', 'constructor', 'toString'];
const prototypeRows = prototypeNames.map((name, i) => baseRow({
  id: 'prototype-' + i, r: name, med: 4 + i, nt: 20
}));
const prototypeActors = prototypeNames.map((name, i) => Object.assign({}, actorRows[0], {
  id: 'prototype-' + i, r: name, med: 4 + i, fr: 0, fsh: 0
}));
const prototypeLeague = P.league(prototypeRows, prototypeActors, S);
assert(prototypeLeague.length === 3 &&
  prototypeNames.every(name => prototypeLeague.some(row => row.r === name)),
  'prototype-named actors must each survive league grouping exactly once');
assert(P.filterRows(prototypeRows, '__proto__', '', '', '', prototypeActors).length === 1,
  'prototype-named actors must remain selectable in the actor filter');

// Actor selection must be indexed O(interviews + actor rows), not the former
// O(interviews x actor rows) nested scan that could freeze a 34k-interview page.
const perfN = 34192;
const perfRows = [];
const perfActors = [];
for (let i = 0; i < perfN; i++) {
  perfRows.push(baseRow({id: 'perf-' + i, r: 'Target Tester'}));
  perfActors.push(Object.assign({}, actorRows[0], {
    id: 'perf-' + i, r: 'Target Tester', med: 4, fr: 0, fsh: 0
  }));
}
const perfStart = Date.now();
const perfSelected = P.filterRows(perfRows, 'Target Tester', '', '', '', perfActors);
const perfElapsed = Date.now() - perfStart;
assert(perfSelected.length === perfN, 'indexed actor filter must retain all matching rows');
assert(perfElapsed < 5000,
  '34,192-interview actor selection must finish under 5 seconds; got ' + perfElapsed + ' ms');
const prototypeDaily = P.dailyTotals([
  {r: '__proto__', d: '__proto__', c: 2},
  {r: 'constructor', d: 'constructor', c: 3}
], '');
assert(prototypeDaily.length === 2 &&
  prototypeDaily.reduce((n, record) => n + record.c, 0) === 5,
  'prototype-like date keys must not corrupt daily grouping');

// Half-second vectors make the supported 1.5-second control exact.
const gapRow = baseRow({g: [2, 3, 5, 7, 11, 13]});
close(P.fastShare(gapRow, 1.5), 10 / 41, 1e-12,
  '1.5-second fast share must include only 0-.499, .5-.999 and 1-1.499 bins');
const fixedBurst = baseRow({med: 2.5, fr: 10, nt: 30});
assert(P.flagsFor(fixedBurst, Object.assign({}, S, {fs: 1.5}), null)[1] &&
  P.flagsFor(fixedBurst, Object.assign({}, S, {fs: 3}), null)[1],
  'session-safe burst run is intentionally fixed at the build-time cutoff');
assert(!P.flagsFor(fixedBurst, Object.assign({}, S, {fs: 1.5}), null)[0] &&
  P.flagsFor(fixedBurst, Object.assign({}, S, {fs: 3}), null)[0],
  'live speed/share cutoff must still change the sustained-speed signal');

// Actor clock/mode quality suppresses actor pace without poisoning the separate
// whole-interview duration assessment.
for (const quality of [{tq: 0}, {m: 1}, {mm: 1}]) {
  const bad = baseRow(Object.assign({med: 0.5, fr: 20, af: 12, nt: 100, rt: 0.1}, quality));
  const flags = P.flagsFor(bad, S, null);
  assert(!flags[0] && !flags[1] && !flags[6],
    'unreliable/non-CAPI actor pace must be suppressed');
}
for (const quality of [{itq: 0}, {im: 1}, {imm: 1}]) {
  const bad = baseRow(Object.assign({af: 1, nc: 1}, quality));
  const flags = P.flagsFor(bad, S, null);
  assert(!flags[2] && !flags[5],
    'unreliable/non-CAPI whole-interview duration must be suppressed');
}
const unknownMode = baseRow({
  mu: 1, imu: 1, tq: 0, lq: 0, itq: 0, ilq: 0,
  med: 0.5, fr: 20, nt: 100, af: 1, rt: 0.1, nsh: 0.9, h: null
});
const unknownModeFlags = P.flagsFor(unknownMode, S, null);
assert(P.isCapi(unknownMode) === false,
  'an unavailable collection mode must not default to CAPI');
assert(!unknownModeFlags[0] && !unknownModeFlags[1] && !unknownModeFlags[2] &&
  !unknownModeFlags[3] && !unknownModeFlags[5] && !unknownModeFlags[6],
  'unknown mode must suppress all actor/interview timing signals');
unknownMode._f = unknownModeFlags;
unknownMode._n = unknownModeFlags.filter(Boolean).length;
unknownMode._r = false;
unknownMode._d = P.domains(unknownMode);
unknownMode._t = 'W';
const unknownModeEvidence = P.evidence(unknownMode, S, P.team([unknownMode]),
  {fastsecs: 2, tzmode: 5.5});
assert(unknownModeEvidence.some(x => x.s.includes('collection mode is unavailable')),
  'unknown-mode suppression must be explained in review evidence');
const unknownModeCsv = parseCSV(P.csv([unknownMode], S, P.team([unknownMode]),
  {fastsecs: 2, tzmode: 5.5}));
const unknownModeHeader = {};
for (let i = 0; i < unknownModeCsv[0].length; i++)
  unknownModeHeader[unknownModeCsv[0][i]] = i;
assert(unknownModeCsv[1][unknownModeHeader.metric_actor_mode] === 'UNKNOWN' &&
  unknownModeCsv[1][unknownModeHeader.interview_mode] === 'UNKNOWN',
  'CSV must label missing actor/interview mode as UNKNOWN, never CAPI');
const unknownActor = Object.assign({}, actorRows[0], {
  id: unknownMode.id, r: unknownMode.r, mu: 1, tq: 0, lq: 0,
  med: 0.5, fr: 20, nt: 100, rt: 0.1, nsh: 0.9
});
assert(P.league([unknownMode], [unknownActor], S)[0].fl === 0,
  'unknown-mode actor must not receive a pace/night/peer league flag');

assert(tierFor([], {on: 1, ilq: 0}) === '',
  'unreliable local dates must not create a multi-day Watch');
assert(tierFor([], {on: 1, ito: 1}) === '',
  'suspect timezone offsets must not create a multi-day Watch');
assert(tierFor([], {pca: 5, pcn: 5, pcf: 0}) === '',
  'routine HQ-only post-completion review edits are context, not a Watch');
assert(tierFor([], {pca: 1, pcf: 1, pco: 1}) === 'W',
  'interviewer edits outside a rejection-correction cycle should Watch');

const mixedOverlap = P.flagsFor(baseRow({m: 1, mm: 1, ov: 4}), S, null);
assert(mixedOverlap[7],
  'valid CAPI overlap buckets must remain visible even in a mixed-mode history');
const churnActor = Object.assign({}, actorRows[1], {ans: 20, ch: 0.4});
const churnView = P.forActor(handoffNoWorkflow, churnActor);
assert(P.flagsFor(churnView, S, null)[4],
  'correction-only actor churn uses substantive answer support, not timed first-pass gaps');

const badTzActor = Object.assign({}, actorRows[1],
  {ans: 20, ansf: 20, nt: 20, nsh: 0.8, lq: 1, to: 1});
assert(!P.flagsFor(P.forActor(handoffNoWorkflow, badTzActor), S, null)[3],
  'night signal must be suppressed for the selected actor when its own offset is suspect');

// Duration context uses whole-interview quality and an explicit null benchmark
// remains authoritative rather than being silently recomputed after filtering.
const benchmark = [];
for (let i = 0; i < 10; i++) benchmark.push(baseRow({id: 'bench-' + i, af: 5 + i}));
const benchmarkWithBad = benchmark.concat([baseRow({id: 'bad-mode', af: 1000, im: 1})]);
close(P.zctx(benchmarkWithBad).med, P.zctx(benchmark).med, 1e-12,
  'mixed/non-CAPI interview must not enter duration benchmark');
assert(P.aggregate(benchmark.map(x => Object.assign({}, x)), S, null).ctx === null,
  'explicitly unavailable duration benchmark must not be recomputed');

const hqContext = baseRow({pca: 5, pcn: 5, pcf: 0,
  pcd: 'HQ Reviewer: a15c, path_review, questions_review, sup_comments, a2'});
hqContext._f = P.flagsFor(hqContext, S, null);
hqContext._n = hqContext._f.filter(Boolean).length;
hqContext._r = P.resub(hqContext);
const hqEvidence = P.evidence(hqContext, S, P.team([hqContext]),
  {fastsecs: 2, tzmode: 5.5});
assert(hqEvidence.some(x => x.t === 'info' && x.s.includes('5 by Supervisor/HQ/API')),
  'HQ post-completion edits must remain visible as provenance context');

// CSV is the same evaluated object as HTML, includes review context and produces a
// rectangular file even when evidence contains commas.
handoff.ov = 3;
handoff.ovt = 3;
handoff.ova = 'Primary Tester';
handoff.ovd = 'Primary Tester @ 2026-07-13 10:00 UTC with case,other';
handoff._f = P.flagsFor(handoff, S, null);
handoff._n = handoff._f.filter(Boolean).length;
handoff._r = P.resub(handoff);
handoff._d = P.domains(handoff);
handoff._t = P.tierFor(handoff);
const csv = P.csv([handoff], S, P.team([handoff]),
  {fastsecs: 2, tzmode: 5.5, hq: 'https://example.invalid'});
const csvLines = csv.split('\n');
assert(csvColumns(csvLines[0]) === csvColumns(csvLines[1]), 'CSV must be rectangular');
assert(csvLines[0].includes('primary_interviewer') && csvLines[0].includes('last_editor') &&
  csvLines[0].includes('resubmit_questions') && csvLines[0].includes('resubmit_edit_events') &&
  csvLines[0].includes('overlap_trace') && csvLines[0].includes('interview_url'),
  'CSV must contain actor, workflow, overlap and deep-link audit fields');

const projected = P.forActor(handoff, actorRows[1]);
projected._f = P.flagsFor(projected, S, null);
projected._n = projected._f.filter(Boolean).length;
projected._r = P.resub(projected);
projected._d = P.domains(projected);
projected._t = P.tierFor(projected);
const projectedCsv = P.csv([projected], S, P.team([projected]),
  {fastsecs: 2, tzmode: 5.5, hq: 'https://example.invalid'}).split('\n');
const headers = parseCsvLine(projectedCsv[0]);
const values = parseCsvLine(projectedCsv[1]);
assert(values[headers.indexOf('metric_actor')] === 'Correction Tester' &&
  values[headers.indexOf('primary_interviewer')] === 'Primary Tester',
  'actor-filter CSV must distinguish metric actor from primary interviewer');
assert(values[headers.indexOf('flags')].includes('Q') &&
  !values[headers.indexOf('flags')].includes('S') &&
  !values[headers.indexOf('flags')].includes('B'),
  'correction actor CSV may own workflow Q but must not inherit primary S/B');

const injection = evaluate(baseRow({
  id: '  =case"\' </script>', k: '\t@key', a: '+24680', r: ' -Primary',
  med: 1, fr: 9, nt: 30, ovd: 'line one\rline two'
}), S);
const injectionCsvText = P.csv([injection], S, P.team([injection]),
  {fastsecs: 2, tzmode: 5.5, hq: 'https://hq.example.test/ws'});
const injectionCsv = parseCSV(injectionCsvText);
assert(injectionCsv.length === 2 && injectionCsv[0].length === injectionCsv[1].length,
  'CSV with a quoted standalone CR must remain one rectangular data row');
const injectionHeader = {};
for (let i = 0; i < injectionCsv[0].length; i++)
  injectionHeader[injectionCsv[0][i]] = i;
const injectionValues = injectionCsv[1];
assert(injectionValues[injectionHeader.interview_id].startsWith("'  ="),
  'CSV must neutralize a formula prefix after leading spaces');
assert(injectionValues[injectionHeader.interview_key].startsWith("'\t@"),
  'CSV must neutralize a formula prefix after a leading tab');
assert(injectionValues[injectionHeader.assignment_id].startsWith("'+"),
  'CSV must neutralize a formula prefix in assignment identifiers');
const expectedAssignment = 'https://hq.example.test/ws/Assignments/%2B24680';
assert(injectionValues[injectionHeader.assignment_url] === expectedAssignment,
  'assignment deep link must be encoded exactly');
assert(injectionCsvText.split(expectedAssignment).length - 1 === 1,
  'assignment deep link must occur exactly once');
assert(injectionValues[injectionHeader.interview_url].includes('%3Dcase%22'),
  'hostile quotes/script text in interview id must be URL-encoded');


/* ---- v1.7.26 SUITETRIAGE: triage sections, chip badges, suite tab badges ---- */
assert(adoText.includes('function updateSections(A,S,team,acts,DT,L,RV){'),
  'renderAll must drive a live section-status engine');
assert(adoText.includes('var RV=renderRemovals(S.resp,S.ws);') &&
       adoText.includes('updateSections(A,S,team,acts,DT,L,RV);'),
  'section findings must be computed from the same pass as the charts');
assert(adoText.includes('function initSections(){') && adoText.includes('initSections();'),
  'section/chip wiring must be installed exactly once at startup');
assert(adoText.includes('function initReviewLayout(){') &&
       adoText.includes("showReviewView('s_att');"),
  'first render must initialize the compact review-list view');
assert(adoText.includes('p.textContent=txt; p.className=') &&
       adoText.includes('function setFind(fid,txt){ var f=el(fid); if(f) f.textContent=txt; }'),
  'pills and findings must be written via textContent, never innerHTML');
assert(adoText.includes("window.parent.postMessage({type:'suso-tab-badge',n:nA+nV,sev:(nA>0?'b':(nV>0?'w':'g'))},'*');"),
  'Behaviour must post an attention badge to the suite parent');
assert(adoText.includes("parent.postMessage({type:'suso-tab-badge',n:st.need,sev:(hA?'b':(st.need>0?'w':'g'))},'*');"),
  'Skips page must post its live need-review badge');
assert(adoText.includes("window.parent.postMessage({type:'suso-tab-badge',n:hard,sev:(hard>0?'b':(K.im>0?'w':'g'))},'*');"),
  'Data QC must post its hard-problem badge');
assert(!adoText.includes('Skip/removal review</button>'),
  'suite tab 2 must carry the new Skips & removals label');
assert(adoText.includes("if(d.sev!=='b'&&d.sev!=='w'&&d.sev!=='g')return;"),
  'suite badge listener must reject unknown severities');

const pctlSorted = [1,2,3,4,5,6,7,8,9,10];
assert(P.pctl([], 0.5) === null, 'pctl of empty input is null');
assert(P.pctl([5], 0.25) === 5 && P.pctl([5], 0.9) === 5, 'pctl of singleton is the value');
assert(P.pctl(pctlSorted, 0.25) === 3, 'nearest-rank p25 of 1..10 is 3');
assert(P.pctl(pctlSorted, 0.5) === 5, 'nearest-rank p50 of 1..10 is 5');
assert(P.pctl(pctlSorted, 0.75) === 8, 'nearest-rank p75 of 1..10 is 8');
assert(P.pctl([10,1,7,3], 0.75) === 7, 'pctl must sort a copy of its input');
const pctlInput = [9,2,5];
P.pctl(pctlInput, 0.5);
assert(pctlInput[0] === 9 && pctlInput[1] === 2, 'pctl must not mutate its input');

console.log('PASS paradata_engine_regression.js');
