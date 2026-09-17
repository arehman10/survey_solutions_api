'use strict';

/* Offline regression for the structured Skip/Removal actor-filter engine. */
const fs = require('fs');
const path = require('path');

const ado = process.argv[2] || path.join(__dirname, '..', 'suso.ado');
const adoText = fs.readFileSync(ado, 'utf8');
const lines = adoText.split(/\r?\n/);

// Reconstruct Stata logical commands before extracting emitted JavaScript.
// Merely slicing between a line's first compound opener and last closer hid the
// v1.7.18 r(198): an interior double-quote+apostrophe had already closed the
// Stata string even though the extracted JavaScript remained valid.
function stataLogicalLines(rawLines) {
  const out = [];
  let current = '';
  for (const raw of rawLines) {
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

const CQ_OPEN = '`"';
const CQ_CLOSE = '"' + "'";
function compoundQuoteErrors(command) {
  let opened = false;
  const errors = [];
  for (let i = 0; i < command.length - 1; i++) {
    const token = command.slice(i, i + 2);
    if (token === CQ_OPEN) {
      if (opened) errors.push('nested opener at byte ' + i);
      else opened = true;
      i++;
    } else if (token === CQ_CLOSE) {
      if (!opened) errors.push('closer outside compound string at byte ' + i);
      else opened = false;
      i++;
    }
  }
  if (opened) errors.push('unclosed compound string');
  return errors;
}

const logicalLines = stataLogicalLines(lines);
const fileWrites = logicalLines.filter(line =>
  /\bfile\s+write\b/.test(line));
assert(fileWrites.length > 0, 'no Stata file write commands found');
for (const line of fileWrites) {
  const errors = compoundQuoteErrors(line);
  assert(errors.length === 0,
    'invalid Stata compound quoting in file write: ' + errors.join(', ') + '\n' + line);
}

// Self-test the lexical gate with the exact failure shape: an accidental close
// in the payload followed by the intended final close.
const quoteGood = "file write `h' " + CQ_OPEN + 'safe' + CQ_CLOSE + ' _n';
const quoteBad = "file write `h' " + CQ_OPEN + 'option value=' + CQ_CLOSE +
  '+actor' + CQ_CLOSE + ' _n';
assert(compoundQuoteErrors(quoteGood).length === 0,
  'compound-quote gate rejected its good fixture');
assert(compoundQuoteErrors(quoteBad).length > 0,
  'compound-quote gate accepted its bad fixture');

let collecting = false;
const source = [];
for (const line of logicalLines) {
  const begin = line.indexOf('`"');
  const end = line.lastIndexOf('"\'');
  if (begin < 0 || end < begin) continue;
  const text = line.slice(begin + 2, end);
  if (text.startsWith('var SKP={')) collecting = true;
  if (collecting) source.push(text);
  if (collecting && text.includes('module.exports=SKP')) break;
}
if (!source.length) throw new Error('could not extract Skip engine SKP from ' + ado);
const holder = {exports: {}};
new Function('module', source.join('\n'))(holder);
const SKP = holder.exports;

// Compile the browser layer too. The pure-engine extraction above would not
// catch a syntax error in the actor selector, synchronized-message listener,
// or dynamic card/summary renderer.
let domCollecting = false;
const hostileActor = `Enumerator <Q> "double" 'single'`;
const hostileKey = `enum-<q>-"-'`;
const domFixture = [{
  ak: hostileKey, an: hostileActor, gk: 'cause', gl: 'Cause', id: 'i1',
  ws: 'Approved by Supervisor', wc: 'approvebysup', t: 'C', q: 1, need: 0, re: 1,
  ev: 3, cp: 1, cev: 3, out: 0, tu: 0, card: '<div>card</div>'
}];
const domSource = ['var SK={meta:{allRole:3,role:3,hasApproved:false},cases:' +
  JSON.stringify(domFixture) + '};'];
for (const line of logicalLines) {
  const begin = line.indexOf('`"');
  const end = line.lastIndexOf('"\'');
  if (begin < 0 || end < begin) continue;
  const text = line.slice(begin + 2, end);
  if (text.startsWith('var SKP={')) domCollecting = true;
  if (domCollecting) domSource.push(text);
  if (domCollecting && text.includes("window.addEventListener('message'")) break;
}
// An incoming suite status with no removal histories must remain selected and
// render zero rows; silently resetting it to All would leak unrelated cases.
domSource.push("setStatus('In progress',false);");
const domElements = Object.create(null);
for (const id of [
  'sk_hist', 'sk_q', 'sk_need', 'sk_re', 'sk_ev', 'sk_scope',
  'sk_compact', 'sk_outside',
  'sk_patterns', 'sk_patterns_empty', 'sk_verify', 'sk_resolved_summary',
  'sk_resolved', 'sk_resolved_more'
]) domElements[id] = {textContent: '', innerHTML: ''};
for (const id of ['s_ver', 's_pat', 's_res', 'p_ver', 'p_res', 'cb_ver', 'cb_res',
  'f_ver', 'f_pat', 'f_res', 'sk_expall', 'sk_collall'
]) domElements[id] = {textContent: '', className: '', style: {},
  querySelector() { return null; }, addEventListener() {},
  setAttribute() {}, getAttribute() { return null; }};
function fakeSelect() { return {
  options: [], value: '',
  set innerHTML(value) { this.options = []; },
  get innerHTML() { return ''; },
  appendChild(option) { this.options.push(option); },
  insertBefore(option, before) {
    const index = this.options.indexOf(before);
    if (index < 0) this.options.push(option); else this.options.splice(index, 0, option);
  },
  addEventListener() {}
}; }
domElements.sk_actor = fakeSelect();
domElements.sk_status = fakeSelect();
const classes = new Set();
const domDocument = {
  body: {classList: {add(x) { classes.add(x); }, contains(x) { return classes.has(x); }}},
  head: {appendChild() {}},
  getElementById(id) { return domElements[id]; },
  querySelectorAll() { return []; },
  createElement(tag) {
    assert(tag === 'option' || tag === 'style', 'unexpected element in compact Skip initialization');
    return {value: '', textContent: ''};
  }
};
const domWindow = {addEventListener() {}};
const domParent = {postMessage() {}};
const domModule = {exports: {}};
new Function('module', 'document', 'window', 'parent', domSource.join('\n'))(
  domModule, domDocument, domWindow, domParent);
assert(domElements.sk_actor.options.length === 2,
  'initActors must create All plus one actor option');
assert(domElements.sk_actor.options[1].value === hostileKey,
  'DOM actor option must preserve the normalized actor key');
assert(domElements.sk_actor.options[1].textContent === hostileActor + ' (1)',
  'DOM actor option must preserve hostile display text without HTML interpolation');
assert(domElements.sk_status.options.some(option => option.value === 'APP'),
  'approved histories must expose the pooled Supervisor/HQ status option');
assert(domElements.sk_status.value === 'In progress' &&
  domElements.sk_status.options.some(option => option.value === 'In progress'),
  'unknown synchronized status must be retained as an explicit zero-case option');
assert(domElements.sk_hist.textContent === '0',
  'unknown synchronized status must render an empty removal scope, not All');

// Selecting "All removal-run actors" must clear the synchronized Behaviour
// selector too.  Sending the visible All-label with an empty key makes that
// label look like an unknown enumerator and leaves Behaviour filtered.
assert(adoText.includes("label:s.value?actorLabel(s.value):''"),
  'Skip All-actors message must carry an empty key and empty label');
assert(!adoText.includes('key:s.value,label:actorLabel(s.value)'),
  'Skip reset must not send the All-actors label as an enumerator');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function one(overrides) {
  return Object.assign({
    ak: 'enum-a', an: 'Enumerator A', gk: 'direct:q1', gl: 'Direct: q1',
    id: 'i1', ws: 'Completed', wc: 'completed', t: 'C', q: 1,
    need: 0, re: 1, ev: 3, cp: 1, cev: 3, out: 0, tu: 0,
    card: '<div>A</div>'
  }, overrides || {});
}

// One interview can contain runs by different people. Ownership must remain on
// the actual removal-run key, so actor B does not inherit actor A's resolved run.
const cases = [
  one(),
  one({ak: 'enum-b', an: 'Enumerator B', id: 'i1', t: 'V', q: 2,
    need: 1, re: 0, ev: 5, gk: 'direct:q2', gl: 'Direct: q2'}),
  one({ak: 'enum-b', an: 'Enumerator B', id: 'i2', t: 'C', q: 3,
    need: 0, re: 3, ev: 4, gk: 'direct:q2', gl: 'Direct: q2'})
];
const all = SKP.stats(SKP.scope(cases, ''));
assert(all.h === 3 && all.q === 6 && all.need === 1 && all.re === 4 && all.ev === 12,
  'all-actor headline cards must preserve original totals');
const a = SKP.scope(cases, 'enum-a');
const ast = SKP.stats(a);
assert(a.length === 1 && ast.q === 1 && ast.need === 0 && ast.re === 1 && ast.ev === 3,
  'actor A must own only actor A removal runs');
const b = SKP.scope(cases, 'enum-b');
const bst = SKP.stats(b);
assert(b.length === 2 && bst.q === 5 && bst.need === 1 && bst.re === 3 && bst.ev === 9,
  'actor B cards must be recomputed from actor B runs');
assert(SKP.scope(cases, 'primary-interviewer').length === 0,
  'an unrelated primary interviewer must not inherit removal runs');

const bp = SKP.patterns(b);
assert(bp.length === 1 && bp[0].h === 2 && bp[0].ni === 2 && bp[0].ev === 9,
  'technical patterns must recompute histories, interviews and events');
const bg = SKP.groups(b);
assert(bg.length === 1 && bg[0].cases.length === 1 && bg[0].need === 1 && bg[0].ni === 1,
  'verification groups must exclude resolved cases and recompute their roll-up');

// No global top-ten truncation may hide a rare pattern. Actor filtering still
// re-ranks the complete structured case set.
const ranking = [];
for (let i = 0; i < 11; i++) {
  ranking.push(one({ak: 'enum-b', an: 'Enumerator B', id: 'b' + i,
    gk: 'bulk:' + i, gl: 'Bulk ' + i, ev: 100 - i}));
}
ranking.push(one({ak: 'enum-a', an: 'Enumerator A', id: 'a-rare',
  gk: 'rare:a', gl: 'Rare A', ev: 1}));
const allRanking = SKP.patterns(ranking);
assert(allRanking.length === 12 && allRanking.some(x => x.k === 'rare:a'),
  'technical summary must retain every pattern without a global top-ten cap');
const rare = SKP.patterns(SKP.scope(ranking, 'enum-a'));
assert(rare.length === 1 && rare[0].k === 'rare:a',
  'selected actor pattern must be re-ranked from complete run details');

// Prototype-like Survey Solutions login/group strings are ordinary data keys.
const proto = [
  one({ak: '__proto__', an: '__proto__', gk: '__proto__', gl: '__proto__'}),
  one({ak: 'constructor', an: 'constructor', gk: 'constructor', gl: 'constructor'})
];
assert(SKP.actors(proto).length === 2, 'prototype-like actor keys must survive grouping');
assert(SKP.patterns(proto).length === 2, 'prototype-like pattern keys must survive grouping');
assert(SKP.scope(proto, '__proto__').length === 1,
  'prototype-like actor key must remain selectable');

// Resolved history must not be silently capped after filtering.
const many = [];
for (let i = 0; i < 250; i++) many.push(one({id: 'a' + i}));
for (let i = 0; i < 250; i++) many.push(one({ak: 'enum-b', an: 'Enumerator B', id: 'b' + i}));
assert(SKP.scope(many, 'enum-b').filter(x => x.t === 'C').length === 250,
  'all selected-actor resolved cases must remain available');
assert(!adoText.includes("r.slice(0,200)") &&
  adoText.includes("r.map(function(x){return x.card;}).join('')"),
  'resolved renderer must display every scoped case without a hidden 200-row cap');

const perf = [];
for (let i = 0; i < 50000; i++) perf.push(one({ak: i % 2 ? 'enum-a' : 'enum-b', id: 'p' + i}));
const started = Date.now();
const perfScoped = SKP.scope(perf, 'enum-b');
SKP.stats(perfScoped);
SKP.patterns(perfScoped);
SKP.groups(perfScoped);
const elapsed = Date.now() - started;
assert(perfScoped.length === 25000, 'large actor scope must retain exact rows');
assert(elapsed < 5000, '50,000-case filter/roll-up must finish under five seconds; got ' + elapsed + ' ms');


/* ---- v1.7.26 SUITETRIAGE: triage sections on the Skips & removals page ---- */
assert(adoText.includes('function updateSkipSections(st,a,p,hasA){'),
  'renderSkip must drive a live section-status engine');
assert(adoText.includes("updateSkipSections(st,a,p,hA);}"),
  'section findings must be computed at the end of the same renderSkip pass');
assert(adoText.includes('initActors();initStatuses();initSkipSections();renderSkip();'),
  'section wiring must install once before the first render');
assert(adoText.includes("secOpen('s_ver',true); }"),
  'only Cases needing verification opens by default');
assert(adoText.includes("Verification cases<span class='n' id='cb_ver'"),
  'chip nav must carry the verification badge');

console.log('PASS skip_filter_engine_regression.js');
