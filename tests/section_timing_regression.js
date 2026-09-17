'use strict';
// Exercises the actual emitted compute core. No alternate implementation.
const assert=require('assert'),fs=require('fs'),path=require('path');
const source=process.argv[2]||path.join(__dirname,'..','suso.ado');
const ado=fs.readFileSync(source,'utf8');let on=false,code=[];
for(const line of ado.split(/\r?\n/)){
 const b=line.indexOf('`"'),e=line.lastIndexOf('"\'');if(b<0||e<b)continue;
 const s=line.slice(b+2,e);if(s.startsWith('var P = {'))on=true;
 if(on)code.push(s);if(on&&s.includes('module.exports=P'))break;
}
const mod={exports:{}};new Function('module',code.join('\n'))(mod);const P=mod.exports;
const data={meta:{hassections:1,lite:1},
 sections:[{id:0,label:'Unmapped activity'},{id:1,label:'Employment'},{id:3,label:'Sales'},{id:9,label:'Not visited'}],
 rows:[{id:'i1',ws:'Completed',wsc:'completed',f:{responsive:'1'}},{id:'i2',ws:'SupervisorApproved',wsc:'approvebysup',f:{responsive:'0'}},{id:'i3',ws:'Completed',wsc:'completed',f:{responsive:'1'}}],
 actors:[{id:'i1',r:'Alpha',p:1},{id:'i1',r:'Beta',p:0},{id:'i2',r:'Alpha',p:1},{id:'i3',r:'Beta',p:1}],
 sa:[[0,'Alpha','alpha'],[0,'Beta','beta'],[1,'Alpha','alpha'],[2,'Beta','beta']],
 // actor, section, first secs, later secs, first events, later events, clock issues
 st:[[0,1,60,0,2,0,0,0],[1,1,180,60,4,1,0,1],[0,3,120,0,2,0,0,0],
     [1,3,0,90,0,2,0,0],[2,1,600,0,4,0,0,0],[2,3,0,0,1,0,1,0],
     [3,1,0,0,1,0,1,0],[0,0,30,0,1,0,0,0]]};
function calc(resp='',ws='',fd='',fv='',period='first',d=data){return P.sectionTiming(d,P.filterRows(d.rows,resp,ws,fd,fv,d.actors),resp,period);}
function section(x,id){return x.rows.find(r=>r.id===id);}
let groups=0;function test(name,f){f();groups++;console.log('PASS '+name);}
test('contributors are summed per interview before quantiles and counts',()=>{
 const x=calc(),r=section(x,1);assert.equal(r.seconds,840);assert.equal(r.observed,3);assert.equal(r.n,2);
 assert.equal(r.median,7);assert.equal(r.p90,10);assert.equal(x.timed,2);
});
test('actor selection includes only selected contributor time',()=>{
 const x=calc(' beta '),r=section(x,1);assert.equal(r.seconds,180);assert.equal(r.median,3);assert.equal(r.observed,2);assert.equal(r.n,1);assert.equal(x.seconds,180);
});
test('status and variable/value filters intersect including value zero',()=>{
 assert.equal(section(calc('Alpha','APP','responsive','0'),1).seconds,600);
 assert.equal(calc('Alpha','APP','responsive','1').selected,0);
 assert.equal(calc('Beta','Completed','responsive','1').seconds,180);
 assert.equal(calc('','Completed','responsive','1').seconds,390);
});
test('all-actor status filters retain both contributors without double-counting IDs',()=>{
 const r=section(calc('','Completed'),1);assert.equal(r.seconds,240);assert.equal(r.n,1);assert.equal(r.median,4);assert.equal(r.observed,2);
});
test('first pass, later corrections and all activity reconcile',()=>{
 const first=calc(),later=calc('','','','','rework'),all=calc('','','','','all');
 assert.equal(first.seconds+later.seconds,all.seconds);assert.equal(later.seconds,150);assert.equal(later.timed,1);
 assert.equal(section(later,1).median,1);assert.equal(section(later,3).median,1.5);
 assert.equal(section(all,1).median,7.5);assert.equal(section(all,3).median,3.5);
 assert.equal(calc('Alpha','','','','rework').seconds,0);
});
test('unmapped time is visible and remains in share denominator',()=>{
 const x=calc();assert.equal(x.seconds,990);assert.equal(x.unmapped,30);assert.equal(section(x,1).share,840/990);
 assert(Math.abs(x.rows.reduce((s,r)=>s+r.share,0)-1)<1e-12);assert.equal(x.rows.at(-1).id,0);
});
test('untimed and unvisited sections do not invent zero-minute quantiles',()=>{
 const x=calc('Beta'),r=section(x,9);assert.equal(r.observed,0);assert.equal(r.median,null);assert.equal(r.p90,null);
 const empty=calc('missing');assert.equal(empty.seconds,0);assert(empty.rows.every(r=>r.share===null&&r.median===null));
 const untimed=calc('Beta','Completed','responsive','1');assert.equal(section(untimed,1).observed,2);assert.equal(section(untimed,1).n,1);
});
test('timestamp issue counts follow actor, status and period',()=>{
 assert.equal(calc().bad,2);assert.equal(calc('Beta','','','','rework').bad,1);
 assert.equal(calc('Alpha','Completed').bad,0);assert.equal(calc('Alpha','APP').bad,1);
});
test('empty or missing metadata is handled without losing raw time',()=>{
 const d={...data,sections:[]};const x=calc('','','','','all',d);assert.equal(x.seconds,1140);assert.equal(x.unmapped,1140);assert.equal(x.rows.length,1);
 assert.equal(P.sectionTiming({rows:[]},[],'','first').seconds,0);
});
test('repeated filtering and period changes never mutate source payload',()=>{
 const original=JSON.stringify(data);for(let n=0;n<5;n++){calc();calc('Beta');calc('','APP','responsive','0','all');}
 assert.equal(JSON.stringify(data),original);
});
test('CSV exports the displayed section results and filter scope',()=>{
 const x=calc('Beta','Completed','responsive','1','all'),r=section(x,1);
 const csv=P.sectionCsv([r],'all',{resp:'Beta',ws:'Completed',fd:'responsive',fv:'1'});
 assert.equal(csv.split('\n').length,2);assert(csv.includes('"all","Employment","2","1","4","4"'));assert(csv.endsWith('"Beta","Completed","responsive","1"'));
 const unsafe=P.sectionCsv([{...r,label:'=1+1,"test"'}],'first',{});assert(unsafe.includes('"\'=1+1,""test"""'));
});
test('large-survey mode retains full actor/status/value granularity',()=>{
 const d={...data,meta:{...data.meta,lite:0}};assert.deepEqual(calc(),calc('','','','','first',d));
});
console.log('PASS section_timing_regression: '+groups+' groups');
