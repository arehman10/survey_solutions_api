'use strict';
const assert=require('assert'),path=require('path');
const {worker,sourceFrom}=require('./history_harness');
const source=process.argv[2]||path.join(__dirname,'..','suso.ado');
const header='interview__id\torder\tevent\tresponsible\trole\ttimestamp_utc\ttz_offset\tparameters';
const line=(id,n,p='q||සිංහල text||')=>id+'\t'+n+'\tAnswerSet\tAlpha\tInterviewer\t2026-05-06T00:00:00.000\t+05:30:00\t'+p;
function file(text,name='fixture.tab'){const b=new Blob([text]);Object.defineProperty(b,'name',{value:name});return b;}
const replacements=n=>[['CHUNK=8*1024*1024','CHUNK='+n]];
let groups=0;
async function test(name,f){await f();console.log('PASS '+name);groups++;}
async function history(w,id){return (await w.request({type:'get',id},'history')).rows;}
(async()=>{
 await test('literal byte boundaries preserve CR, LF, CRLF, EOF and Unicode IDs',async()=>{
  const records=[line('A',4),line(' B ',1),line('a',2),line('සිංහල',1),line('A',2,'q||last "literal" value||')];
  const text='\uFEFF'+header+'\r\n'+records[0]+'\r'+records[1]+'\n\n'+records[2]+'\r\n'+records[3]+'\n'+records[4];
  for(const chunk of [1,2,3,7,31,128,8192]){
   const w=worker(source,replacements(chunk)),r=await w.request({type:'index',file:file(text)});
   assert.equal(r.rows,5);assert.equal(r.interviews,3);assert.equal(r.ranges,5);
   const a=await history(w,' a ');assert.deepStrictEqual(a.map(x=>x.order),['2','2','4']);
   assert.deepStrictEqual(a.map(x=>x.seq),[3,5,1]);
   for(const row of a){assert.equal(row.byte,Buffer.byteLength(text.slice(0,text.indexOf(records[row.seq-1]))));}
   assert.equal((await history(w,'සිංහල'))[0].parameters,'q||සිංහල text||');
   assert.equal((await history(w,'b'))[0].seq,2);
  }
 });
 await test('repeated IDs and trim/case variants preserve every row without merging distinct IDs',async()=>{
  const entries=[];for(let i=1;i<=500;i++)entries.push(line('A',i));
  entries.push(line(' a ',501),line('AB',1),line('A',502));
  const w=worker(source,replacements(257)),r=await w.request({type:'index',file:file(header+'\n'+entries.join('\n'))});
  assert.equal(r.rows,503);assert.equal(r.interviews,2);const a=await history(w,'A');assert.equal(a.length,502);
  assert.deepStrictEqual(a.map(x=>Number(x.order)),Array.from({length:502},(_,i)=>i+1));assert.equal((await history(w,'AB')).length,1);
 });
 await test('non-first ID column, blank IDs and short rows retain explicit counts',async()=>{
  const text='event\tparameters\tinterview__id\torder\ttimestamp_utc\nAnswerSet\tq||1||\tX\t1\t2026-05-06T00:00:00\nAnswerSet\tx\t \t2\t2026-05-06T00:00:00\nAnswerSet\tx\nAnswerSet\ty\tX\t3\t2026-05-06T00:00:00';
  const w=worker(source,replacements(11)),r=await w.request({type:'index',file:file(text)});assert.equal(r.rows,2);assert.equal(r.blank,2);
  assert.deepStrictEqual((await history(w,'x')).map(x=>x.seq),[1,4]);
 });
 await test('quoted multiline mode preserves literal tabs, quotes, UTF-8 and fragmented IDs',async()=>{
  const text=header+'\r\n'+line('"A"',1,'"q||line 1\tline 2\nසිංහල ""quoted""||"')+'\r\n'+line('B',2)+'\n'+line('A',3);
  for(const chunk of [1,7,64]){
   const w=worker(source,replacements(chunk)),r=await w.request({type:'index',file:file(text),quoted:true});assert.equal(r.rows,3);assert.equal(r.interviews,2);
   const a=await history(w,'A');assert.equal(a.length,2);assert.equal(a[0].parameters,'q||line 1\tline 2\nසිංහල "quoted"||');
  }
 });
 await test('fragmentation fallback rescans all matching events with exact source rows',async()=>{
  const w=worker(source,[...replacements(53),['MAX_RANGES=500000','MAX_RANGES=2']]);
  const r=await w.request({type:'index',file:file(header+'\n'+[line('A',1),line('B',1),line('A',2),line('B',2),line('A',3)].join('\n'))});
  assert(r.scanMode);assert.equal(r.rows,5);assert.deepStrictEqual((await history(w,'A')).map(x=>x.seq),[1,3,5]);
 });
 await test('switching files during a pending read cannot publish stale rows or Ready',async()=>{
  let release;const old={name:'old.tab',size:100,slice(){return {arrayBuffer(){return new Promise(r=>release=r);}};}};
  const w=worker(source);w.post({type:'index',file:old});
  const ready=await w.request({type:'index',file:file(header+'\n'+line('NEW',1),'new.tab')});assert.equal(ready.name,'new.tab');
  release(new Uint8Array(100).buffer);await new Promise(r=>setImmediate(r));
  assert.equal(w.messages.filter(x=>x.type==='ready').length,1);assert.equal(w.messages.filter(x=>x.type==='error').length,0);
  assert.equal((await history(w,'NEW')).length,1);assert.equal((await w.request({type:'get',id:'OLD'},'notfound')).id,'OLD');
 });
 await test('prefetched read failures are reported and never produce a partial Ready',async()=>{
  const b=file(header+'\n'+line('A',1));let n=0;
  const f={name:'failed.tab',size:b.size,slice(a,z){return {arrayBuffer(){return ++n===2?Promise.reject(Error('simulated local read denial')):b.slice(a,z).arrayBuffer();}};}};
  const w=worker(source,replacements(64)),error=await w.request({type:'index',file:f},'error');
  assert(error.message.includes('read denial'));assert.equal(w.messages.filter(x=>x.type==='ready').length,0);
 });
 await test('short reads and invalid ID encoding fail explicitly',async()=>{
  const short={name:'short.tab',size:100,slice(){return {arrayBuffer:async()=>new Uint8Array(4).buffer};}};
  const w=worker(source),err=await w.request({type:'index',file:short},'error');assert(err.message.includes('incomplete'));
  const invalid=new Blob([header+'\n',new Uint8Array([0xc3,0x28]),'\t1\tAnswerSet\tA\t1\t2026-05-06T00:00:00\t+00:00\tx']);
  assert((await worker(source).request({type:'index',file:invalid},'error')).message);
 });
 await test('empty and header-only files are distinguished; progress is bounded and monotonic',async()=>{
  assert((await worker(source).request({type:'index',file:file('')},'error')).message.includes('empty'));
  const w=worker(source,replacements(23)),r=await w.request({type:'index',file:file(header)});assert.equal(r.rows,0);
  const ps=w.messages.filter(x=>x.type==='progress');assert(ps.every((p,i)=>p.done<=p.total&&(!i||p.done>=ps[i-1].done)));
  assert(r.seconds>=0);
 });
 await test('source privacy and memory constraints retain local slices and no persistent store',async()=>{
  const s=sourceFrom(source);for(const forbidden of ['fetch(','XMLHttpRequest','indexedDB','localStorage','sessionStorage','file.text('])assert(!s.includes(forbidden),forbidden);
  assert(s.includes('sourceFile.slice(at,Math.min(end,at+CHUNK))'));assert(s.includes('carry.length>64*1024*1024'));
  assert(s.includes('URL.revokeObjectURL(workerUrl)'));
 });
 console.log('PASS history_index_regression: '+groups+' groups');
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
