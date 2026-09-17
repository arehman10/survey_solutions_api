'use strict';
/* Run the actual pure JS embedded in suso.ado; no synthetic implementation. */
const assert=require('assert'),fs=require('fs'),path=require('path');
const ado=fs.readFileSync(process.argv[2]||path.join(__dirname,'..','suso.ado'),'utf8');
let active=false;const lines=[];
for(const line of ado.split(/\r?\n/)){
  const b=line.indexOf('`"'),e=line.lastIndexOf('"\'');if(b<0||e<b)continue;
  const s=line.slice(b+2,e);if(s.startsWith('var P = {'))active=true;
  if(active)lines.push(s);if(active&&s.includes('module.exports=P'))break;
}
const holder={exports:{}};new Function('module',lines.join('\n'))(holder);const P=holder.exports;
const S={fs:2,...P.presets.standard};
function row(extra={}){return {id:'i1',k:'11-22',a:'1',r:'Primary',le:'Secondary',fi:'Primary',na:2,ho:1,pas:.8,ws:'Completed',wsc:'completed',m:0,mm:0,mu:0,tq:1,lq:1,itq:1,im:0,imm:0,imu:0,ilq:1,ito:0,nt:20,nc:1,af:20,act:20,med:10,fsh:0,nsh:0,ch:0,fr:0,rt:1,ov:0,pans:100,to:0,rj:0,rbc:0,re:null,rq:null,rb:null,fdc:0,cop:0,cu:0,wsm:0,on:0,pcf:0,ve:0,...extra};}
function actor(extra={}){return {id:'i1',r:'Primary',p:1,f:1,l:0,ans:100,ansf:100,q:100,ss:1,share:.8,act:20,af:20,nt:20,med:10,fsh:0,nsh:0,ch:0,rt:1,fr:0,ov:0,tq:1,lq:1,m:0,mm:0,mu:0,tz:5.5,to:0,...extra};}
function secondary(extra={}){return actor({r:'Secondary',p:0,f:0,l:1,share:.2,...extra});}
function analyze(rows,actors,settings=S,resp='',ctx=null){return P.aggregate(P.filterRows(rows,resp,'','','',actors),settings,ctx);}
function ev(a,settings=S){return P.evidence(a.flagged[0],settings,{med:10,nq:100,act:20},{fastsecs:2});}
let n=0;function check(name,fn){fn();n++;console.log('PASS '+name);}
check('live night cutoff agrees across queue, evidence, league',()=>{
  const h=Array(24).fill(0);h[21]=20;const a=actor({h}),cfg={...S,n1:20};
  const result=analyze([row()],[a],cfg),g=P.league([row()],[a],cfg)[0];
  assert.equal(result.tot[3],1);assert.equal(g.fl,1);assert.equal(g.mnsh,1);
  assert(ev(result,cfg).some(e=>e.scope==='actor'&&/Primary: 100%/.test(e.s)));
  assert.equal(analyze([row()],[a],S).flagged.length,0);
});
check('live speed share agrees and exact boundaries exclude cutoff itself',()=>{
  const g=Array(41).fill(0);g[5]=20;g[6]=10;const a=actor({g,med:2.5});
  assert.equal(P.fastShare(a,2.5),0);assert.equal(P.fastShare(a,3),2/3);
  assert.equal(P.league([row()],[a],{...S,fs:3})[0].mfsh,2/3);
});
check('unsupported cutoff is not rounded or allowed to include overflow bin',()=>{
  const g=Array(41).fill(0);g[4]=10;g[40]=20;
  for(const x of [2.1,2.0000000001,.5000000001,30,20,10.5,0,-1,NaN,Infinity,'2']){assert(!P.validFast(x));assert.equal(P.fastShare({g,fsh:1},x),null);}
  for(let x=.5;x<=10;x+=.5)assert(P.validFast(x));
  assert.equal(P.fastShare({g},10),1/3);
});
check('secondary speed and streak enter default queue with actor evidence',()=>{
  const actors=[actor(),secondary({med:1,fr:12})],all=analyze([row()],actors);
  assert.equal(all.flagged.length,1);assert.equal(all.tiers.V,1);assert.equal(all.tot[0],1);
  assert.equal(all.flagged[0].med,10);assert.deepEqual(all.flagged[0]._reviewActors,['Secondary']);
  const evidence=ev(all);assert(evidence.some(e=>e.scope==='actor'&&/Secondary.*1.0 s/.test(e.s)));
  assert(!evidence.some(e=>/Primary.*typical/.test(e.s)));
  assert.equal(analyze([row()],actors,S,'Secondary').tiers.V,1);
  assert.equal(analyze([row()],actors,S,'Primary').flagged.length,0);
  const csv=P.csv(all.flagged,S,{med:10,nq:100,act:20},{fastsecs:2});
  assert(csv.includes('review_actors,actor_flag_evidence'));assert(csv.includes('Secondary: SB'));
});
check('different contributors cannot pool pace and churn into a stronger tier',()=>{
  const a=analyze([row()],[actor({med:1}),secondary({ch:.4})]);
  assert.equal(a.tiers.W,1);assert.equal(a.tiers.V,0);assert.equal(a.flagged[0]._n,2);
  assert.equal(a.flagged[0]._d.n,1);
  assert.equal(a.flagged[0]._actorFindings.filter(x=>x._t==='W').length,2);
});
check('secondary overlap does not combine with primary pace and night',()=>{
  const actors=[actor({med:1,nsh:.9}),secondary({ov:6})];
  const a=analyze([row({med:1,nsh:.9,ov:6,ova:'Secondary'})],actors);
  assert.equal(a.tiers.V,1);assert.equal(a.tiers.A,0);assert.equal(a.flagged[0].ov,0);
  assert(ev(a).some(x=>/^Secondary recorded answers/.test(x.s)));
});
check('same-actor three domains still investigate and only one interview is counted',()=>{
  const a=analyze([row()],[actor(),secondary({med:1,nsh:.9,ch:.4})]);
  assert.equal(a.tiers.A,1);assert.equal(a.n,1);assert.equal(a.tot[0],1);
  const both=analyze([row()],[actor({med:1}),secondary({med:1})]);assert.equal(both.tot[0],1);
});
check('selected actor does not inherit shared final-state workflow but retains context',()=>{
  const r=row({fdc:1,fck:1,fda:0,fad:0,feb:0,fbe:1,flu:0,fnd:0}),actors=[actor(),secondary({med:1})];
  const own=analyze([r],actors,S,'Secondary');assert.equal(own.tiers.W,1);
  assert(ev(own).some(x=>x.t==='info'&&/Final-data review/.test(x.s)));
  assert.equal(P.league([r],actors,S).find(x=>x.r==='Primary').fl,1);
  assert.equal(analyze([r],[actor(),secondary()],S,'Secondary').flagged.length,0);
});
check('known re-completion actor retains workflow attribution; unknown contributor is not lost',()=>{
  const actors=[actor(),secondary()],r=row({rj:1,rbc:1,re:0,rq:0,rb:1,rba:'Secondary'});
  assert.equal(analyze([r],actors).tiers.A,1);assert.equal(analyze([r],actors,S,'Secondary').tiers.A,1);
  assert.equal(analyze([r],actors,S,'Primary').flagged.length,0);
  assert.equal(P.league([r],actors,S).find(x=>x.r==='Primary').fl,0);
  assert(ev(analyze([r],actors)).some(x=>/Re-completed by Secondary/.test(x.s)));
  const missing=row({rj:1,rbc:1,re:1,rq:1,rb:1,rba:'Workflow only'}),out=analyze([missing],actors);
  assert.equal(out.tiers.V,1);assert(out.flagged[0]._reviewActors.includes('Workflow only'));
});
check('mode, clock quality and sample support suppress only corresponding actor flags',()=>{
  for(const extra of [{m:1},{mm:1},{mu:1},{tq:0}]){
    const a=analyze([row()],[actor(),secondary({med:1,fr:20,...extra})]);assert.equal(a.flagged.length,0);
  }
  for(const extra of [{lq:0},{to:1},{nt:2}]) assert.equal(analyze([row()],[actor(),secondary({nsh:1,...extra})]).flagged.length,0);
});
check('lite mode uses stored exact build-time shares and independent actor scores',()=>{
  const actors=[actor(),secondary({nsh:.8,fsh:.9,med:1,fr:12})],out=analyze([row()],actors);
  assert.equal(out.tiers.V,1);const l=P.league([row()],actors,S).find(x=>x.r==='Secondary');
  assert.equal(l.mnsh,.8);assert.equal(l.mfsh,.9);assert.equal(l.fl,1);
});
check('reference duration context stays consistent between filtered queue and league',()=>{
  const r=row({af:100}),actors=[actor({af:100})],ctx={med:Math.log(20),mad:.1};
  const out=analyze([r],actors,S,'Primary',ctx);assert(out.flagged[0]._f[5]);
  assert.equal(P.league([r],actors,S,'Primary',ctx)[0].fl,1);
});
check('repeated filtering and sensitivity changes do not contaminate raw data',()=>{
  const r=row(),actors=[actor(),secondary({med:1,fr:12})],before=JSON.stringify({r,actors});
  for(let i=0;i<3;i++){analyze([r],actors);analyze([r],actors,S,'Secondary');analyze([r],actors,{...S,fs:.5,burst:20});}
  assert.equal(JSON.stringify({r,actors}),before);
});
check('a responsive interview remains searchable when the filtered duration benchmark clears its signal',()=>{
  const data=[],actors=[];
  for(let i=0;i<60;i++){
    const value=i<42?'0':'1',duration=i===42?13.4:(i<42?1+(i%7)*.05:10+(i-42)*.7);
    const r=row({id:'f'+i,k:'filter-key-'+i,af:duration,act:duration,ho:0,ws:'ApprovedByHeadquarters',wsc:'approvebyhq',f:{lf_responsive:value}});
    data.push(r);actors.push(actor({id:r.id,af:duration,act:duration}));
  }
  function scope(value,status='ApprovedByHeadquarters',who='Primary'){
    const rows=P.filterRows(data,who,status,'lf_responsive',value,actors);
    return P.aggregate(rows,S,P.zctx(P.filterRows(data,'',status,'lf_responsive',value,actors)));
  }
  const before=JSON.stringify({data,actors}),all=scope(''),filtered=scope('1');
  assert.equal(all.flagged.find(r=>r.id==='f42')._t,'W');
  assert(filtered.rows.some(r=>r.id==='f42'&&r.f.lf_responsive==='1'));
  assert(!filtered.flagged.some(r=>r.id==='f42'));
  const found=P.reviewMatches(filtered,' FILTER-KEY-42 ','');
  assert.equal(found.length,1);assert.equal(found[0]._t,'');
  assert.equal(P.reviewMatches(filtered,'filter-key-42','W').length,0);
  assert.equal(P.reviewMatches(filtered,'filter-key-42','N').length,1);
  assert.equal(P.reviewMatches(scope('0'),'filter-key-42','').length,0,'value zero is a real filter');
  assert.equal(P.reviewMatches(scope('1','Completed'),'filter-key-42','').length,0);
  assert.equal(P.reviewMatches(scope('1','ApprovedByHeadquarters','Other'),'filter-key-42','').length,0);
  assert.equal(P.reviewMatches(filtered,'','').length,filtered.flagged.length,'default review list remains flags only');
  assert(P.reviewMatches(filtered,'','N').every(r=>!r._t));
  assert.equal(new Set(P.reviewMatches(all,'filter-key','').map(r=>r.id)).size,60,'search has no duplicate interviews');
  assert(P.csv(found,S,P.team(filtered.rows),{}).includes('NO_ACTIVE_SIGNALS'));
  data[42].f.lf_responsive='';assert(!scope('1').rows.some(r=>r.id==='f42'));data[42].f.lf_responsive='1';
  assert.equal(JSON.stringify({data,actors}),before,'search/filtering do not mutate source values');
});
check('CLI and browser have matching explicit validation and actor projections remain serialized',()=>{
  assert(ado.includes('fastsecs() must be 0.5 to 10 seconds in steps of 0.5.'));
  assert(ado.includes("speed.setCustomValidity('Use 0.5 to 10 seconds, in steps of 0.5.')"));
  assert(ado.includes('P.league(rows,D.actors,S,S.resp,A.ctx)'));
  assert(ado.includes('quietly rename ovm_actor pa_ovm'));
  assert(ado.includes('"h":[`ahv\'],"g":[`agv\']'));
});
console.log('PASS report_metrics_regression.js: '+n+' behavioral groups');
