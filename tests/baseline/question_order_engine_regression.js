'use strict';

/* Executable browser-core regression for Question timing ordering. */
const fs = require('fs');
const path = require('path');

const ado = process.argv[2] || path.join(__dirname, '..', 'suso.ado');
const adoText = fs.readFileSync(ado, 'utf8');
const lines = adoText.split(/\r?\n/);
const source = [];
let collecting = false;
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

const resetLine = lines.find(line =>
  line.includes("el('c_qorder').addEventListener('click'"));
if (!resetLine) throw new Error('Questionnaire-order restore control is not wired');
if (!resetLine.includes("qSortKey='o';qSortDir=-1;renderQuestions();"))
  throw new Error('order restore must select ascending static order and rerender');
if (/resetSettings|c_resp|c_ws|c_q['"]/.test(resetLine))
  throw new Error('order restore must not clear actor, status, or search filters');
if (!adoText.includes("var qSortKey='o', qSortDir=-1"))
  throw new Error('initial Question timing view must use ascending static order');
if (!adoText.includes('id="c_qorder"') || !adoText.includes('Questionnaire order'))
  throw new Error('report must expose the dedicated order-restore button');
if (!adoText.includes('P.questionSort(rows,qSortKey,qSortDir)'))
  throw new Error('filtered rows must pass through the shared tested comparator');

const holder = {exports: {}};
new Function('module', source.join('\n'))(holder);
const P = holder.exports;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function names(rows) {
  return rows.map(row => row.v).join(',');
}

const team = [
  {s: '', v: 'zeta_unknown', o: 5, med: 80},
  {s: '', v: 'b9_you', o: 3, med: 18},
  {s: '', v: 'b0', o: 2, med: 21},
  {s: '', v: 'sc3a', o: 1, med: 7},
  {s: '', v: 'alpha_unknown', o: 4, med: null},
  {s: 'Completed', v: 'b0', o: 2, med: 20},
  {s: 'Completed', v: 'alpha_unknown', o: 4, med: 6}
];
const actor = [
  {r: 'Actor B', k: 'actor b', s: '', v: 'alpha_unknown', o: 4, med: 6},
  {r: 'Actor B', k: 'actor b', s: '', v: 'sc3a', o: 1, med: 8},
  {r: 'Actor B', k: 'actor b', s: 'APP', v: 'alpha_unknown', o: 4, med: 5},
  {r: 'Actor B', k: 'actor b', s: 'APP', v: 'sc3a', o: 1, med: 9}
];
const index = P.questionIndex(actor);

let rows = P.questionRows(team, index, '', '');
P.questionSort(rows, 'o', -1);
assert(names(rows) === 'sc3a,b0,b9_you,alpha_unknown,zeta_unknown',
  'default order must follow questionnaire rank, with unknowns already ranked at the tail');

rows = P.questionRows(team, index, ' Actor B ', 'APP');
P.questionSort(rows, 'o', -1);
assert(names(rows) === 'sc3a,alpha_unknown' && rows[0].o === 1 && rows[1].o === 4,
  'actor/status intersection must retain global questionnaire ranks');

rows = P.questionRows(team, index, '', '').filter(row => row.v.includes('unknown'));
P.questionSort(rows, 'o', -1);
assert(names(rows) === 'alpha_unknown,zeta_unknown',
  'text search must filter without changing the surviving questionnaire order');

rows = P.questionRows(team, index, '', '');
P.questionSort(rows, 'med', 1);
assert(names(rows) === 'zeta_unknown,b0,b9_you,sc3a,alpha_unknown',
  'click-sort descending must remain available and keep missing metrics last');
P.questionSort(rows, 'med', -1);
assert(names(rows) === 'sc3a,b9_you,b0,zeta_unknown,alpha_unknown',
  'clicking again must reverse the metric sort while keeping missing metrics last');

rows = [{v: 'zeta', o: null}, {v: 'beta', o: 2}, {v: 'alpha', o: null},
  {v: 'aardvark', o: 2}];
P.questionSort(rows, 'o', -1);
assert(names(rows) === 'aardvark,beta,alpha,zeta',
  'rank ties and missing ranks must use deterministic variable-name ordering');

console.log('PASS question_order_engine_regression.js');
