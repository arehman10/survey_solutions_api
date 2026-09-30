'use strict';
// Bounded compute/Blob benchmark; does not measure browser UI or network drives.
const assert=require('assert'),path=require('path');
const {worker}=require('../tests/history_harness');
const args=process.argv.slice(2),option=(n,d)=>{const i=args.indexOf(n);return i<0?d:args[i+1];};
const count=Number(option('--rows','1000000')),runs=Number(option('--runs','3'));
const current=option('--source',path.join(__dirname,'..','suso.ado')),baseline=option('--baseline','');
const shape=option('--shape','grouped'),perInterview=100,interviews=Math.ceil(count/perInterview);
const id=i=>'000000000000000000000000'+String(i).padStart(8,'0');
const blocks=['interview__id\torder\tevent\tresponsible\trole\ttimestamp_utc\ttz_offset\tparameters\r\n'];
let block='';
for(let i=0;i<count;i++){
 const who=shape==='interleaved'?i%interviews:Math.floor(i/perInterview);
 const order=shape==='interleaved'?Math.floor(i/interviews)+1:i%perInterview+1;
 block+=id(who)+'\t'+order+'\tAnswerSet\tEnumerator\tInterviewer\t2026-05-06T15:11:50.605\t+05:30:00\tq'+order+'||Synthetic answer; repeated visits and Unicode සිංහල remain verbatim||\r\n';
 if((i+1)%10000===0){blocks.push(Buffer.from(block));block='';}
}
if(block)blocks.push(Buffer.from(block));
const file=new Blob(blocks);Object.defineProperty(file,'name',{value:'synthetic-'+shape+'.tab'});blocks.length=0;block='';
(async()=>{
 const results={};
 for(let run=0;run<runs;run++)for(const [label,source] of (run%2?[['current',current],['baseline',baseline]]:[['baseline',baseline],['current',current]])){
  if(!source)continue;const w=worker(source),start=performance.now();
  const r=await w.request({type:'index',file},'ready',120000),ms=performance.now()-start;
  assert.equal(r.rows,count);assert.equal(r.interviews,interviews);
  for(const i of [0,Math.floor(interviews/2),interviews-1]){
   const h=await w.request({type:'get',id:id(i)},'history',120000);
   const expected=shape==='interleaved'?Math.floor((count-1-i)/interviews)+1:Math.min(perInterview,count-i*perInterview);
   assert.equal(h.rows.length,expected);assert.equal(h.rows[0].order,'1');
   assert(h.rows.every(x=>x.parameters.includes('සිංහල')));
  }
  (results[label]||(results[label]=[])).push(Number(ms.toFixed(1)));
 }
 const median=a=>a.slice().sort((x,y)=>x-y)[Math.floor(a.length/2)];
 const out={shape,rows:count,interviews,bytes:file.size,runs,ms:results,medianMs:Object.fromEntries(Object.entries(results).map(([k,v])=>[k,median(v)])),countsAndSampleHistoriesVerified:true};
 if(results.baseline)out.speedup=Number((median(results.baseline)/median(results.current)).toFixed(2));
 console.log(JSON.stringify(out,null,2));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
