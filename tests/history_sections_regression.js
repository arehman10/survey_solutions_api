'use strict';
const assert=require('assert'),path=require('path');
const {worker}=require('./history_harness');
const source=process.argv[2]||path.join(__dirname,'..','suso.ado'),H=worker(source).sections;
const defs=[{id:0,label:'Unmapped activity'},{id:1,label:'Employment'},{id:3,label:'Sales'}],map=[['employees',1],['sales',3]];
const base=Date.UTC(2026,4,6),event=(n,t,ev,actor='',params='',role='1')=>({order:String(n),seq:n,timestamp:new Date(base+t*1000).toISOString(),event:ev,responsible:actor,parameters:params,role,tz:'+00:00:00'});
const rows=[event(1,0,'Resumed','A'),event(2,60,'AnswerSet','A','employees||2||'),
 event(3,90,'AnswerDeclaredValid','','sales||'),event(4,120,'AnswerSet','','sales||100||'),event(5,150,'Paused'),
 event(6,600,'Resumed','A'),event(7,660,'AnswerSet','A','employees||3||roster-2'),event(8,720,'Completed','A'),
 event(9,1000,'ReceivedByHeadquarters',''),event(10,1100,'CommentSet','HQ','sales||review||','3'),
 event(11,1160,'CommentSet','HQ','sales||more review||','3'),event(12,1190,'AnswerSet','','unknown||1||',''),
 event(13,1220,'AnswerDeclaredValid','','unknown||','')];
const calc=(r=rows,visible=r,period='all',m=map,d=defs)=>H.summarize(H.allocate(r,m,d,1800000,true),visible,d,period);
let n=0;function test(label,f){f();console.log('PASS '+label);n++;}
test('full raw-chain section totals retain unnamed events as an included subtotal',()=>{
 const r=calc();assert.equal(r.seconds,390);assert.equal(r.noActor,150);assert.equal(r.events,13);
 assert.equal(r.rows.find(x=>x.id===1).seconds,210);assert.equal(r.rows.find(x=>x.id===1).noActor,30);
 assert.equal(r.rows.find(x=>x.id===3).seconds,120);assert.equal(r.rows.find(x=>x.id===3).noActor,60);
 assert.equal(r.rows.find(x=>x.id===0).seconds,60);assert.equal(r.rows.find(x=>x.id===0).noActor,60);
 assert.equal(r.rows.reduce((s,x)=>s+x.seconds,0),r.seconds);
});
test('actor filtering uses raw unnamed identity and preserves original interval lengths',()=>{
 const unnamed=rows.filter(x=>H.actor(x)==='(no responsible actor)');const r=calc(rows,unnamed);
 assert.equal(r.seconds,150);assert.equal(r.noActor,150);
 assert.equal(calc(rows,rows.filter(x=>x.responsible==='A')).seconds,180);
 assert.equal(calc(rows,rows.filter(x=>x.responsible==='HQ')).seconds,60);
 assert.equal(calc(rows,rows.filter(x=>x.event==='AnswerSet')).seconds,180);
});
test('first-completion periods reconcile for named and unnamed events',()=>{
 const first=calc(rows,rows,'first'),later=calc(rows,rows,'rework');assert.equal(first.seconds,270);assert.equal(later.seconds,120);
 assert.equal(first.noActor,90);assert.equal(later.noActor,60);assert.equal(first.seconds+later.seconds,calc().seconds);
});
test('automatic validation keeps the prior section; unknown questions reset it',()=>{
 const a=H.allocate(rows,map,defs,1800000,true);assert.equal(a[2].section,1);assert.equal(a[2].seconds,30);
 assert.equal(a[11].section,0);assert.equal(a[12].section,0);assert.equal(a[12].seconds,30);
});
test('an entirely unnamed session has measurable time without a fictitious actor',()=>{
 const r=[event(1,0,'Resumed'),event(2,60,'AnswerSet','','employees||1||'),event(3,90,'AnswerDeclaredInvalid','  ','employees||'),event(4,120,'Completed')];
 assert.equal(calc(r).seconds,120);assert.equal(calc(r).noActor,120);assert.equal(H.actor(r[2]),'(no responsible actor)');
});
test('known handoffs, resumes, pauses, completion and long gaps do not create work time',()=>{
 const r=[event(1,0,'Resumed','A'),event(2,60,'AnswerSet','A','employees||1||'),event(3,120,'AnswerSet','B','sales||1||'),event(4,4000,'AnswerSet','B','sales||2||'),event(5,4010,'Paused','B'),event(6,4020,'AnswerSet','B','sales||3||')];
 const a=H.allocate(r,map,defs,1800000,true);assert.deepStrictEqual(a.map(x=>x.seconds),[0,60,0,0,10,0]);
});
test('invalid/missing timestamps cannot bridge a larger artificial gap',()=>{
 const r=[event(1,0,'Resumed','A'),event(2,60,'AnswerSet','A','employees||1||'),event(3,90,'AnswerSet','A','employees||2||'),event(4,120,'AnswerSet','A','employees||3||')];r[2].timestamp='';
 const a=H.allocate(r,map,defs,1800000,true);assert.deepStrictEqual(a.map(x=>x.seconds),[0,60,0,0]);assert.equal(calc(r).bad,1);
 r[2].timestamp=event(3,30,'').timestamp;assert.equal(calc(r).bad,1);assert.equal(H.allocate(r,map,defs,1800000,true)[2].seconds,0);
});
test('preload answers stay visible but create neither active time nor section context',()=>{
 const r=[event(1,0,'InterviewCreated','A'),event(2,0,'AnswerSet','A','employees||preload||'),event(3,30,'SupervisorAssigned','A'),event(4,600,'Resumed','A'),event(5,660,'AnswerSet','A','sales||1||')];
 const a=H.allocate(r,map,defs,1800000,true);assert.equal(a[1].section,0);assert.equal(calc(r).seconds,60);
});
test('missing metadata, quoted parameters and roster instances conserve timing',()=>{
 const no=calc(rows,rows,'all',[],[]);assert.equal(no.seconds,390);assert.equal(no.rows.length,1);assert.equal(no.rows[0].label,'Unmapped activity');
 const r=[event(1,0,'Resumed','A'),event(2,60,'AnswerSet','A','"employees||2||roster-1"')];assert.equal(calc(r).rows.find(x=>x.id===1).seconds,60);
});
test('empty intersections stay empty and source records remain unchanged',()=>{
 const copy=JSON.stringify(rows);assert.equal(calc(rows,[]).seconds,0);assert.equal(calc(rows,[]).rows.length,0);calc();calc(rows,rows,'first');assert.equal(JSON.stringify(rows),copy);
});
test('custom inactivity limits preserve exact-boundary intervals and split larger gaps',()=>{
 const r=[event(1,0,'Resumed','A'),event(2,30,'AnswerSet','A','employees||1||'),event(3,61,'AnswerSet','A','employees||2||')];
 const a=H.allocate(r,map,defs,30000,true);assert.deepStrictEqual(a.map(x=>x.seconds),[0,30,0]);
 const s=require('./history_harness').sourceFrom(source);
 const C=new Function(s+'\nreturn HCompact;')();
 assert.equal(C.plan([{...r[0],_time:{utcMs:0},_gap:null},{...r[1],_time:{utcMs:30000},_gap:30000}],30000).filter(x=>x.k==='gap').length,0);
});
console.log('PASS history_sections_regression: '+n+' groups');
