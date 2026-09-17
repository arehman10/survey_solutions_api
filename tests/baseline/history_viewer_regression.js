'use strict';

/* Offline regression for the local-file raw history viewer embedded in suso.ado. */
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
  if (text.startsWith('/* suso raw history viewer')) collecting = true;
  if (!collecting) continue;
  if (text.startsWith('</script>')) break;
  source.push(text);
}
if (!source.length) throw new Error('could not extract history viewer from ' + ado);

const holder = {exports: {}};
new Function('module', source.join('\n') +
  '\nmodule.exports={core:HCore,worker:historyWorkerMain,compact:HCompact};')(holder);
const H = holder.exports.core;
const HC = holder.exports.compact;
const historyWorkerMain = holder.exports.worker;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function bytes(s) {
  return new TextEncoder().encode(s);
}
function chunkedRecords(input, chunkSize, quoted = false) {
  const data = bytes(input);
  let offset = 0;
  let carry = new Uint8Array(0);
  const records = [];
  function cat(a, b) {
    const c = new Uint8Array(a.length + b.length);
    c.set(a);
    c.set(b, a.length);
    return c;
  }
  while (offset < data.length) {
    const end = Math.min(data.length, offset + chunkSize);
    const chunk = data.slice(offset, end);
    const buffer = carry.length ? cat(carry, chunk) : chunk;
    const tail = H.walkRecords(buffer, false, rec => records.push(rec.slice()), quoted);
    carry = buffer.slice(tail);
    offset = end;
  }
  H.walkRecords(carry, true, rec => records.push(rec.slice()), quoted);
  return records;
}

const fixture =
  '\uFEFFinterview__id\torder\tevent\tresponsible\trole\ttimestamp_utc\ttz_offset\tparameters\r\n' +
  'A\t1\tAnswerSet\tEnum α\tInterviewer\t2026-05-06T15:11:50.605\t+05:30:00\t"q1||line 1\tline 2\nසිංහල ""quoted""||"\r\n' +
  'B\t2\tPaused\tEnum B\tInterviewer\t2026-05-06T15:12:00.000\t+05:30:00\t\r\n' +
  'A\t3\tReceivedBySupervisor\t\t<UNKNOWN ROLE>\t2026-05-10T14:13:13.394\t-04:00:00';

for (const size of [1, 2, 3, 5, 7, 4096]) {
  const records = chunkedRecords(fixture, size, true);
  assert(records.length === 4, 'quoted multiline/CRLF parse failed at chunk size ' + size);
  const header = H.parseRecord(records[0], true);
  const schema = H.schema(header);
  assert(schema.id === 0 && schema.sourceUtc, 'BOM/header schema failed at chunk size ' + size);
  const first = H.parseRecord(records[1], true);
  assert(first.length === 8, 'quoted row field count failed at chunk size ' + size);
  assert(first[7] === 'q1||line 1\tline 2\nසිංහල "quoted"||',
    'quoted tabs/newlines/doubled quotes/Unicode failed at chunk size ' + size);
  const last = H.parseRecord(records[3], true);
  assert(last.length === 7, 'missing trailing parameters must remain a short raw row');
  const row = H.rowFrom(last, schema, 3, 999);
  assert(row.parameters === '', 'missing trailing parameters must pad to empty in viewer projection');
}

// Lone CR, LF and EOF without a final line break are independent logical rows.
const mixed = chunkedRecords('a\tb\rc\td\ne\tf', 1).map(H.parseRecord);
assert(mixed.length === 3 && mixed[2][1] === 'f', 'mixed newline/EOF handling failed');

// A quote in the middle of an unquoted field is literal, not a multiline opener.
const literal = chunkedRecords('h1\th2\nA\tx"y\n', 1).map(H.parseRecord);
assert(literal[1][1] === 'x"y', 'literal unquoted quote handling failed');

// Production parity: Survey Solutions mode follows Stata bindquote(nobind).
// Quotes are ordinary parameter bytes and must not be stripped or unescaped.
const susoLiteral = chunkedRecords(
  'interview__id\tparameters\nA\t"q1||a ""quoted"" value||"\n', 2, false
).map(record => H.parseRecord(record, false));
assert(susoLiteral.length === 2 &&
  susoLiteral[1][1] === '"q1||a ""quoted"" value||"',
  'default Survey Solutions TSV mode must preserve literal quotes byte-for-text');

// Invalid UTF-8 is rejected rather than silently replacing sensitive text.
let invalidRejected = false;
try { H.decode(new Uint8Array([0xc3, 0x28])); } catch (_) { invalidRejected = true; }
assert(invalidRejected, 'invalid UTF-8 must be rejected');

// Current exports: source is UTC and reported local time uses each event offset.
let t = H.timeInfo({timestamp: '2026-05-06T15:11:50.605', tz: '+05:30:00'}, true);
assert(t.utc === '2026-05-06 15:11:50.605', 'UTC formatting drifted');
assert(t.local === '2026-05-06 20:41:50.605', '+05:30 local reconstruction failed');
t = H.timeInfo({timestamp: '2026-05-10T14:13:13.394', tz: '-04:00:00'}, true);
assert(t.local === '2026-05-10 10:13:13.394', '-04:00 local reconstruction failed');

// Legacy exports: timestamp is local wall time; UTC is available only with a valid offset.
t = H.timeInfo({timestamp: '2026-05-10T10:13:13.394', tz: '-04:00:00'}, false);
assert(t.utc === '2026-05-10 14:13:13.394' && t.local === '2026-05-10 10:13:13.394',
  'legacy local-to-UTC reconstruction failed');
t = H.timeInfo({timestamp: '2026-05-10T10:13:13.394', tz: '99:00'}, false);
assert(t.utc === '' && t.local === '2026-05-10 10:13:13.394',
  'invalid legacy offset must not manufacture UTC');

// Stata real()-style decimal order: empty/hex are invalid and fall back to source row.
assert(H.orderValue('') === null && H.orderValue('0x10') === null && H.orderValue('1e2') === 100,
  'order parser must accept only decimal/scientific numbers');
const ordered = H.orderRows([
  {order: '10', seq: 3}, {order: '', seq: 2}, {order: '0x1', seq: 1},
  {order: '2', seq: 4}, {order: '2', seq: 5}
]);
assert(ordered.map(x => x.seq).join(',') === '1,2,4,5,3',
  'order/source-row stable sorting failed');

// Event filtering searches all user-visible raw fields and category styling is deterministic.
const malicious = {order: '1', event: 'AnswerSet', responsible: '<img onerror=1>',
  role: 'Interviewer', timestamp: '2026-01-01T00:00:00', tz: '+00:00',
  parameters: '</script><script>alert(1)</script>'};
assert(H.matches(malicious, 'onerror') && H.matches(malicious, '</script>'),
  'raw search must preserve, not reinterpret, hostile text');
assert(H.kind('AnswerSet') === 'answer' && H.kind('AnswerRemoved') === 'warn' &&
  H.kind('ApprovedByHeadquarters') === 'workflow', 'event category mapping failed');

// Source-level resource/privacy contracts: stream slices in a Worker, never whole-file text,
// never render source values through innerHTML, and retain fragmented-ID ranges/fallback.
for (const needle of [
  "sourceFile.slice(at,Math.min(end,at+CHUNK)).arrayBuffer()",
  "r.push([start,end,dataRow,1])",
  "scanMode=true;ranges=0",
  "worker.postMessage({type:'index',file:file,quoted:E('hv_dialect').value==='quoted'})",
  "p.textContent=r.parameters",
  "Raw parameters can contain answers, GPS coordinates, and other sensitive data",
  "_suso_para_history_js `fh'",
  "data-history-id='+Q+attr(r.id)+Q",
  "b.classList.contains('hv-open')",
  "window.susoOpenHistory=openHistory"
]) assert(adoText.includes(needle), 'missing history-viewer contract: ' + needle);
assert(!source.join('\n').includes('file.text('), 'viewer must not load the full file as text');
assert(!source.join('\n').includes('reader.readAsText'), 'viewer must not use whole-file FileReader');
assert(!source.join('\n').includes('innerHTML'), 'raw history viewer must not inject source values as HTML');

// Minimal DOM regression for the public queue/detail handoff. This proves the
// raw ID is assigned as a value/text payload, the History section is opened,
// and a missing local file produces a clear one-time prompt without HTML sinks.
function domOpenAcceptance() {
  class FakeNode {
    constructor() {
      this.value = '';
      this.disabled = false;
      this.style = {};
      this.textContent = '';
      this.className = '';
      this.focused = false;
      this.scrolled = false;
    }
    addEventListener() {}
    focus() { this.focused = true; }
    scrollIntoView() { this.scrolled = true; }
    appendChild() {}
  }
  const ids = ['hv_status', 'hv_file', 'hv_id', 'hv_load', 'history_explorer'];
  const nodes = Object.fromEntries(ids.map(id => [id, new FakeNode()]));
  global.document = {
    readyState: 'complete',
    getElementById: id => nodes[id] || (nodes[id] = new FakeNode()),
    createElement: () => new FakeNode(),
    addEventListener() {}
  };
  global.window = {};
  const domModule = {exports: {}};
  new Function('module', source.join('\n'))(domModule);
  assert(typeof window.susoOpenHistory === 'function',
    'history viewer must publish a queue/detail integration function');
  const hostileId = 'id-<img onerror=alert(1)>';
  assert(window.susoOpenHistory(hostileId), 'valid detail ID should open History');
  assert(nodes.hv_id.value === hostileId, 'detail ID must be assigned exactly to the value control');
  assert(nodes.history_explorer.scrolled, 'detail action must scroll the History section into view');
  assert(nodes.hv_file.focused, 'unindexed detail action must focus the local file chooser');
  assert(nodes.hv_status.textContent.includes(hostileId) &&
    nodes.hv_status.textContent.includes('Choose the matching paradata.tab'),
  'unindexed detail action must clearly queue the exact ID and request the local file');
  assert(window.susoOpenHistory('x'.repeat(501)) === false,
    'oversize cross-component history IDs must be rejected');
  delete global.document;
  delete global.window;
}
domOpenAcceptance();

/* ---- v1.7.26 compact-timeline planner ---------------------------------- */
{
  const mk = (order, event, actor, role, ts, tz, params) => ({
    order: String(order), event, responsible: actor, role,
    timestamp: ts, tz, parameters: params || '', seq: order, byte: 0,
  });
  const sample = [
    mk(1, 'InterviewerAssigned', 'SL_Col_Thara39', '1', '2026-05-13T07:56:33.850', '05:30:00', 'SL_Col_Thara39'),
    mk(2, 'KeyAssigned', '', '', '2026-05-13T07:56:33.850', '05:30:00', '80-72-14-00'),
    mk(3, 'AnswerSet', 'SL_Col_Thara39', '1', '2026-05-13T07:56:33.850', '05:30:00', 'squ_id0||101810136||'),
    mk(4, 'AnswerSet', 'SL_Col_Thara39', '1', '2026-05-13T07:56:35.100', '05:30:00', 'q1||yes||'),
    mk(5, 'Paused', 'SL_Col_Thara39', '1', '2026-05-13T08:40:35.100', '05:30:00', ''),
    mk(6, 'Resumed', 'SL_Col_Thara39', '1', '2026-05-13T10:00:00.000', '05:30:00', ''),
    mk(7, 'AnswerSet', 'SL_Col_Thara39', '1', '2026-05-13T09:59:59.000', '05:30:00', 'q2||3||'),
    mk(8, 'Completed', 'SL_Col_Thara39', '1', '2026-05-14T02:00:00.000', '05:30:00', ''),
    mk(9, 'ReceivedBySupervisor', 'Sup01', '2', '2026-05-14T04:00:00.000', '-04:00:00', ''),
  ];
  let prev = null;
  for (const r of sample) {
    const t = H.timeInfo(r, true);
    r._time = t;
    r._gap = prev !== null && t.utcMs !== null ? t.utcMs - prev : null;
    if (t.utcMs !== null) prev = t.utcMs;
  }
  const plan = HC.plan(sample, 30 * 60000);
  const kinds = plan.map(x => x.k).join(',');
  const days = plan.filter(x => x.k === 'day');
  const gaps = plan.filter(x => x.k === 'gap');
  const rows = plan.filter(x => x.k === 'r');
  assert(rows.length === sample.length, 'compact plan must keep every event: ' + kinds);
  assert(days.length === 3, 'expected day rails for 13 May, 14 May, and the offset change, got ' + days.length);
  assert(days[0].label.indexOf('Wed 13 May 2026') === 0 && days[0].label.indexOf('05:30:00') > 0,
    'first day rail must carry weekday, date, and offset: ' + days[0].label);
  assert(days[2].label.indexOf('-04:00:00') > 0, 'offset change must open a new rail: ' + days[2].label);
  assert(gaps.length === 4, 'expected four session breaks (44 min, 79 min, overnight, 2 h), got ' + gaps.length);
  assert(gaps[0].label.indexOf('44.0 min pause') === 0 && gaps[0].label.indexOf('30 min session gap cap') > 0,
    'session break label must state duration and cap: ' + gaps[0].label);
  assert(gaps[2].label.indexOf('h pause') > 0, 'overnight break must be reported in hours: ' + gaps[2].label);
  assert(rows[1].dimT === true && rows[2].dimT === true, 'repeated identical times must be dimmed');
  assert(rows[1].dimA === false && rows[3].dimA === true, 'actor dimming must track actor changes only');
  assert(rows[0].pill === null && rows[2].pill === null, 'sub-second and first gaps must stay silent');
  assert(rows[3].pill && rows[3].pill.cls === 'g1' && rows[3].pill.txt === '+1.3 s',
    'small quiet gaps get a grey pill: ' + JSON.stringify(rows[3].pill));
  assert(rows[6].pill && rows[6].pill.cls === 'rev' && rows[6].pill.txt.indexOf('-1') === 0,
    'clock reversal must be a red pill: ' + JSON.stringify(rows[6].pill));
  const afterGap = plan[plan.indexOf(gaps[0]) + 1];
  assert(afterGap.k === 'r' && afterGap.dimT === false && afterGap.dimA === false,
    'first row after a session break must render undimmed');
  assert(afterGap.pill === null, 'rows behind a session break must not repeat the gap as a pill');
  assert(HC.compactGap(500) === null && HC.compactGap(null) === null, 'silent-gap contract');
  assert(HC.compactGap(90000).cls === 'g2', 'minute-scale gaps are amber');
  assert(HC.shortDur(2 * 86400000) === '2.0 d', 'multi-day durations use days');
  console.log('PASS compact-timeline planner (day rails, session breaks, dimming, pills)');
}


async function workerAcceptance() {
  const messages = [];
  const waitFor = type => new Promise((resolve, reject) => {
    const started = Date.now();
    const timer = setInterval(() => {
      const found = messages.find(x => x.type === type);
      if (found) { clearInterval(timer); resolve(found); }
      else if (Date.now() - started > 5000) {
        clearInterval(timer);
        reject(new Error('worker timeout waiting for ' + type + ': ' + JSON.stringify(messages)));
      }
    }, 5);
  });
  global.self = {postMessage: message => messages.push(message), onmessage: null};
  
historyWorkerMain();
  const file = new Blob([fixture], {type: 'text/tab-separated-values'});
  Object.defineProperty(file, 'name', {value: 'fragmented-paradata.tab'});
  self.onmessage({data: {type: 'index', file, quoted: true}});
  const ready = await waitFor('ready');
  assert(ready.rows === 3 && ready.interviews === 2 && ready.ranges === 3 && ready.fragmented,
    'worker must index fragmented A,B,A IDs as three exact spans');
  self.onmessage({data: {type: 'get', id: ' A '}});
  const history = await waitFor('history');
  assert(history.id === 'A' && history.rows.length === 2,
    'worker retrieval must return both and only fragmented A records');
  assert(history.rows[0].order === '1' && history.rows[1].order === '3',
    'worker retrieval must sort by order with exact source-row fallback metadata');
  assert(history.rows[0].parameters.includes('සිංහල'),
    'worker retrieval must preserve Unicode and quoted multiline parameters');
  messages.length = 0;
  const literalFile = new Blob([
    'interview__id\torder\tevent\tresponsible\trole\ttimestamp_utc\ttz_offset\tparameters\n' +
    'L\t1\tAnswerSet\tEnum\tInterviewer\t2026-05-06T00:00:00.000\t+00:00:00\t"q1||a ""quoted"" value||"\n'
  ], {type: 'text/tab-separated-values'});
  Object.defineProperty(literalFile, 'name', {value: 'literal-paradata.tab'});
  self.onmessage({data: {type: 'index', file: literalFile}});
  const literalReady = await waitFor('ready');
  assert(literalReady.dialect === 'suso', 'worker default must be Survey Solutions literal TSV');
  messages.length = 0;
  self.onmessage({data: {type: 'get', id: 'L'}});
  const literalHistory = await waitFor('history');
  assert(literalHistory.rows.length === 1 &&
    literalHistory.rows[0].parameters === '"q1||a ""quoted"" value||"',
  'worker default must preserve literal parameter quotes exactly');
  delete global.self;
}

workerAcceptance().then(() => {
  console.log('PASS history_viewer_regression');
}).catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
