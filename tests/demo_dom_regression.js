'use strict';
// Real HTML templates + real page JS; synthetic payloads. No Stata calculations.
const assert=require('assert');
const fs=require('fs'), path=require('path'), os=require('os'), cp=require('child_process');
const {JSDOM,VirtualConsole}=require('jsdom');
const root=path.resolve(__dirname,'..'), source=path.resolve(process.argv[2]||path.join(root,'suso.ado'));
const output=fs.mkdtempSync(path.join(os.tmpdir(),'suso-demo-'));
cp.execFileSync(process.env.PYTHON||'python3',[path.join(root,'tools/render_demo.py'),'--source',source,'--out',output],{stdio:'pipe'});
const opened=[];
function doc(name,workerRows){
  const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e));
  const dom=new JSDOM(fs.readFileSync(path.join(output,name+'.html'),'utf8'),{
    runScripts:'dangerously',pretendToBeVisual:true,virtualConsole:vc,
    beforeParse(w){w.TextDecoder=TextDecoder;w.TextEncoder=TextEncoder;w.scrollTo=()=>{};w.HTMLElement.prototype.scrollIntoView=()=>{};
      if(workerRows){
        w._workers=[];w._revoked=[];w.URL.createObjectURL=()=> 'blob:synthetic-worker';w.URL.revokeObjectURL=u=>w._revoked.push(u);
        // UI messaging only. Actual file/worker integrity is tested separately.
        w.Worker=class {constructor(){this.messages=[];w._workers.push(this);}terminate(){this.terminated=true;}
          postMessage(m){this.messages.push(m);if(m.type==='index')this.onmessage({data:{type:'ready',name:'synthetic.tab',rows:workerRows.length,interviews:1,seconds:1.2,dialect:'suso',schema:{sourceUtc:true}}});
            if(m.type==='get')this.onmessage({data:{type:'history',id:m.id,rows:workerRows,schema:{sourceUtc:true}}});}
        };
      }
    }
  });
  opened.push(dom);return {w:dom.window,d:dom.window.document,errors};
}
function change(x,id,value,event='change'){const el=x.d.getElementById(id);assert(el,'missing '+id);el.value=value;el.dispatchEvent(new x.w.Event(event,{bubbles:true}));return el;}
function click(x,sel){const e=x.d.querySelector(sel);assert(e,'missing clickable '+sel);e.click();return e;}
const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
try{
  const b=doc('behaviour'); assert.deepStrictEqual(b.errors,[],'behavior initialization errors');
  assert(b.d.body.classList.contains('review-workspace'));
  assert.deepStrictEqual([...b.d.querySelectorAll('.wrap > .sblock')].filter(x=>!x.hidden).map(x=>x.id),['s_att']);
  assert(b.d.querySelector('[data-case-id="'+id(1)+'"]'),'fast primary actor case');
  // Acceptance for the secondary-actor correction, beyond UI-only tests.
  assert(b.d.querySelector('[data-case-id="'+id(5)+'"]'),'default queue must include secondary actor risk');
  click(b,'[data-case-id="'+id(3)+'"]');
  assert(b.d.getElementById('review_detail').textContent.includes('employees'),'selected removal evidence');
  assert(b.d.getElementById('review_detail').textContent.includes('Affected questions'),'source-generated removal card copied to side panel');
  assert.strictEqual(b.d.activeElement.id,'case_title','focus moves to evidence title');
  b.d.getElementById('review_detail').dispatchEvent(new b.w.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
  assert(b.d.getElementById('review_detail').textContent.includes('Select an interview'));
  assert.strictEqual(b.d.activeElement.getAttribute('data-case-id'),id(3),'Escape restores list focus');
  change(b,'review_search','00-00-00-07','input');
  assert.strictEqual(b.d.querySelectorAll('#t_worst tbody .wrow').length,1);
  change(b,'review_search','','input');
  change(b,'c_top','2');
  assert.strictEqual(b.d.querySelectorAll('#t_worst tbody .wrow').length,2,'pagination size');
  click(b,'#review_next');assert(b.d.getElementById('review_count').textContent.startsWith('3–'));
  change(b,'c_top','25');
  change(b,'c_resp','Bilal Ahmed');
  assert(b.d.querySelector('[data-case-id="'+id(5)+'"]'),'same secondary case under actor filter');
  change(b,'c_resp','');
  change(b,'c_ws','SupervisorApproved');
  assert.strictEqual(b.d.querySelectorAll('#t_worst tbody .wrow').length,0,'approved scope has no illustrative findings');
  change(b,'c_ws','');
  click(b,'[data-main-view="s_enum"]');
  assert(!b.d.getElementById('s_enum').hidden && b.d.getElementById('s_att').hidden);
  click(b,'[data-review-actor="Amina Khan"]');
  assert.strictEqual(b.d.getElementById('c_resp').value,'Amina Khan');
  assert(!b.d.getElementById('s_att').hidden);
  change(b,'c_resp','');
  click(b,'[data-main-view="s_qt"]');
  assert(!b.d.getElementById('s_qt').hidden && b.d.getElementById('s_att').hidden);
  assert(b.d.getElementById('t_q').textContent.includes('employees'));
  const qr=b.w.D.q.filter(q=>q.s===''),savedShares=qr.map(q=>q.fsh);
  qr[0].fsh=.76;qr[1].fsh=null;qr[2].fsh=0;b.w.renderQuestions();
  assert(b.d.querySelector('#t_q tr th:last-child').textContent.includes('Timed reaches < 2.0 s (%)'));
  assert.deepStrictEqual([...b.d.querySelectorAll('#t_q tr td:last-child')].map(x=>x.textContent),['76.0%','—','0.0%']);
  click(b,'#t_q tr th:last-child');click(b,'#t_q tr th:last-child');
  assert.deepStrictEqual([...b.d.querySelectorAll('#t_q tr td:last-child')].map(x=>x.textContent),['76.0%','0.0%','—']);
  assert.strictEqual(qr[0].fsh,.76,'percentage formatting does not change raw values');
  qr.forEach((q,i)=>q.fsh=savedShares[i]);click(b,'#c_qorder');
  // Section timing must use the same intersected interview scope and own-actor time.
  click(b,'[data-main-view="s_sections"]');
  assert(!b.d.getElementById('s_sections').hidden);
  change(b,'c_resp','Amina Khan');change(b,'c_ws','Completed');
  change(b,'c_fd','region');change(b,'c_fv','1');
  assert(!b.d.getElementById('s_sections').hidden,'global filters retain the selected page');
  assert.strictEqual(b.d.getElementById('st_hours').textContent,'1.12');
  assert.strictEqual(b.d.getElementById('st_timed').textContent,'3');
  assert.strictEqual(b.d.getElementById('st_mapped').textContent,'98.0%');
  assert(b.d.getElementById('st_scope').textContent.includes('region = 1'));
  const sectionCells=sid=>[...b.d.querySelectorAll('#t_sections [data-section-id="'+sid+'"] td')].map(e=>e.textContent);
  assert.strictEqual(sectionCells(1)[4],'0.39','Employment total sums scoped interview times');
  assert(Math.abs(Number(sectionCells(1)[2])-10.85)<.051,'median uses per-interview totals');
  assert.deepStrictEqual(sectionCells(5).slice(0,4),['0','0','—','—'],'unvisited section has no invented quantiles');
  change(b,'st_period','rework');
  assert.strictEqual(b.d.getElementById('st_hours').textContent,'0.05');
  assert.strictEqual(b.d.getElementById('st_timed').textContent,'1');
  assert.strictEqual(sectionCells(3)[2],'3.0');
  change(b,'st_period','all');assert.strictEqual(b.d.getElementById('st_hours').textContent,'1.17');
  change(b,'st_sort','total');assert.strictEqual(b.d.querySelector('#t_sections tbody tr').getAttribute('data-section-id'),'3');
  change(b,'st_search','employment','input');
  assert.strictEqual(b.d.querySelectorAll('#t_sections tbody tr').length,1);
  assert.strictEqual(b.d.getElementById('st_hours').textContent,'1.17','section search does not change scope denominator');
  change(b,'st_search','does not exist','input');assert(b.d.getElementById('t_sections').textContent.includes('No sections match'));
  change(b,'st_search','','input');change(b,'st_sort','design');
  change(b,'c_ws','APP');assert(!b.d.getElementById('st_empty').hidden);
  assert.strictEqual(b.d.getElementById('st_hours').textContent,'0.00');
  assert.strictEqual(b.d.getElementById('st_mapped').textContent,'—');
  change(b,'c_resp','');change(b,'c_ws','');change(b,'c_fd','');change(b,'st_period','first');
  assert(b.d.getElementById('st_csv'),'section CSV control');
  click(b,'[data-main-view="s_att"]');click(b,'[data-case-id="'+id(1)+'"]');
  click(b,'#review_detail .hv-open');
  assert(!b.d.getElementById('s_hist').hidden);assert.strictEqual(b.d.getElementById('hv_id').value,id(1));
  assert.deepStrictEqual(b.errors,[],'behavior interaction errors');
  const event=(n,t,ev,actor,params='')=>({order:String(n),seq:n,event:ev,responsible:actor,role:'1',timestamp:new Date(Date.UTC(2026,4,6)+t*1000).toISOString(),tz:'+00:00:00',parameters:params});
  const raw=[event(1,0,'Resumed','Amina Khan'),event(2,60,'AnswerSet','Amina Khan','employees||2||'),event(3,90,'AnswerDeclaredValid','','sales||'),event(4,120,'AnswerSet','','sales||100||'),event(5,150,'Paused','')];
  const h=doc('behaviour',raw);h.d.dispatchEvent(new h.w.Event('DOMContentLoaded'));click(h,'[data-main-view="s_hist"]');
  assert.strictEqual(h.w.getComputedStyle(h.d.querySelector('#s_hist .question-help')).maxWidth,'none');
  assert.strictEqual(h.d.querySelectorAll('#s_hist .question-help li').length,6);
  Object.defineProperty(h.d.getElementById('hv_file'),'files',{value:[new h.w.File(['synthetic'],'synthetic.tab')],configurable:true});
  h.d.getElementById('hv_file').dispatchEvent(new h.w.Event('change'));
  assert(h.d.getElementById('hv_status').textContent.includes('indexed locally in 1.2 s'),h.d.getElementById('hv_status').textContent);
  change(h,'hv_id','assignment: 101','input');click(h,'#hv_load');
  assert.strictEqual(h.w._workers[0].messages.at(-1).id,id(1));
  if(h.errors.length)throw h.errors[0].detail||h.errors[0];
  assert(h.d.getElementById('hv_section_scope').textContent.includes('Assignment 101'));
  assert.strictEqual(h.d.getElementById('hv_section_totals').textContent,'2.50 active min');
  const timingTable=h.d.getElementById('hv_section_table');
  assert.deepStrictEqual([...timingTable.querySelectorAll('thead th')].map(x=>x.textContent),['Questionnaire section','Events','Timed intervals','Active min','Share (%)']);
  for(const cell of timingTable.querySelectorAll('thead th:not(:first-child),tbody td'))assert.strictEqual(h.w.getComputedStyle(cell).textAlign,'center');
  for(const cell of timingTable.querySelectorAll('tbody th')){assert.strictEqual(h.w.getComputedStyle(cell).textAlign,'left');assert.strictEqual(h.w.getComputedStyle(cell).color,'rgb(26, 26, 26)');}
  assert.strictEqual(h.w.getComputedStyle(h.d.querySelector('.hv-section-times')).paddingLeft,'14px');
  assert(!h.d.getElementById('hv_section_totals').textContent.includes('no responsible actor'));
  assert([...timingTable.querySelectorAll('tbody tr')].every(x=>x.cells.length===5));
  const actorRows=[...h.d.querySelectorAll('#hv_actor_panel label')];
  actorRows.find(x=>x.textContent.includes('Amina Khan')).querySelector('input').click();
  assert.strictEqual(h.d.getElementById('hv_section_totals').textContent,'1.50 active min');
  change(h,'hv_search','AnswerSet','input');
  assert.strictEqual(h.d.getElementById('hv_section_totals').textContent,'0.50 active min','filtering must not bridge hidden events');
  change(h,'hv_section_period','rework');assert(h.d.getElementById('hv_section_table').textContent.includes('No events match'));
  change(h,'hv_section_period','all');change(h,'hv_search','','input');
  h.w.D.rows[1].a='101';change(h,'hv_id','assignment: 101','input');click(h,'#hv_load');
  assert.strictEqual(h.d.querySelectorAll('#hv_suggest button').length,2,'multiple assignment interviews require an explicit choice');
  click(h,'#hv_suggest button:last-child');assert.strictEqual(h.w._workers[0].messages.at(-1).id,id(2));
  change(h,'hv_id','assignment: 99999','input');click(h,'#hv_load');assert(h.d.getElementById('hv_status').textContent.includes('No report interview matches'));
  h.d.getElementById('hv_file').dispatchEvent(new h.w.Event('change'));assert(h.w._workers[0].terminated);assert.strictEqual(h.w._revoked.length,1);
  assert.deepStrictEqual(h.errors,[],'history sections/assignment interactions');
  const sk=doc('skips');
  assert.deepStrictEqual(sk.errors,[],'skip initialization errors');
  assert.strictEqual(sk.d.getElementById('sk_hist').textContent,'3');
  assert.strictEqual(sk.d.getElementById('sk_need').textContent,'2');
  assert.strictEqual(sk.d.querySelectorAll('#sk_resolved .case').length,1);
  change(sk,'sk_actor','chandra silva');
  assert.strictEqual(sk.d.getElementById('sk_need').textContent,'0');
  assert.strictEqual(sk.d.querySelectorAll('#sk_resolved .case').length,1,'resolved history retained under actor filter');
  const dq=doc('dataqc');assert.deepStrictEqual(dq.errors,[],'Data QC initialization errors');
  assert.strictEqual(dq.d.getElementById('k_imiss').textContent,'2');
  change(dq,'c_fd','region');change(dq,'c_fv','1');
  assert.strictEqual(dq.d.getElementById('k_imiss').textContent,'2');
  change(dq,'c_fv','2');assert.strictEqual(dq.d.getElementById('k_imiss').textContent,'0');
  // The iframe payloads are the same standalone docs, not hand-written lookalikes.
  const shell=new JSDOM(fs.readFileSync(path.join(output,'paradata-example.html'),'utf8'));
  ['behaviour','skips','dataqc'].forEach((name,i)=>assert.strictEqual(shell.window.document.querySelector('#p'+(i+1)+' iframe').getAttribute('srcdoc'),fs.readFileSync(path.join(output,name+'.html'),'utf8')));
  shell.window.close();
  const focused=doc('section-timing-example');
  assert(!focused.d.getElementById('s_sections').hidden,'focused example opens the actual new page');
  assert.deepStrictEqual(focused.errors,[]);
  const historyDemo=doc('history-timing-example');
  assert(!historyDemo.d.getElementById('s_hist').hidden);
  assert.strictEqual(historyDemo.d.getElementById('hv_section_totals').textContent,'6.50 active min');
  assert.deepStrictEqual(historyDemo.errors,[]);
  const filterDemo=doc('filter-search-example'),candidate='00000000-0000-0000-0000-000000000043';
  assert(filterDemo.d.querySelector('[data-case-id="'+candidate+'"]'),'responsive case stays searchable after its signal clears');
  assert.strictEqual(filterDemo.w.D.rows[42].f.lf_responsive,'1');
  assert(!filterDemo.w.lastA.flagged.some(r=>r.id===candidate));
  assert(filterDemo.d.getElementById('review_detail').textContent.includes('lf_responsive = 1'));
  assert(filterDemo.d.getElementById('review_detail').textContent.includes('no active review signals'));
  assert(filterDemo.d.querySelector('#t_worst .tier.N'));
  change(filterDemo,'c_fv','');assert(filterDemo.d.querySelector('#t_worst .tier.W'),'unfiltered duration benchmark raises Watch');
  change(filterDemo,'c_fv','1');assert(filterDemo.d.querySelector('#t_worst .tier.N'));
  change(filterDemo,'review_tier','W');assert(filterDemo.d.getElementById('t_worst').textContent.includes('Choose All priorities'));
  change(filterDemo,'review_tier','');change(filterDemo,'c_fv','0');
  assert(!filterDemo.d.querySelector('[data-case-id="'+candidate+'"]'));
  assert(filterDemo.d.getElementById('t_worst').textContent.includes('outside the current'));
  change(filterDemo,'c_fv','1');change(filterDemo,'review_search','does-not-exist','input');
  assert(filterDemo.d.getElementById('t_worst').textContent.includes('No interview matches'));
  change(filterDemo,'review_search','00-00-00-43','input');
  let savedCsv='';const anchorClick=filterDemo.w.HTMLAnchorElement.prototype.click;
  filterDemo.w.HTMLAnchorElement.prototype.click=function(){savedCsv=decodeURIComponent(this.href.split(',').slice(1).join(','));};
  click(filterDemo,'#c_csv');filterDemo.w.HTMLAnchorElement.prototype.click=anchorClick;
  assert(savedCsv.includes(candidate));assert(savedCsv.includes('NO_ACTIVE_SIGNALS'));
  assert.strictEqual(savedCsv.trim().split('\n').length,2,'CSV uses the same search/priority scope as the table');
  click(filterDemo,'[data-case-id="'+candidate+'"]');click(filterDemo,'#review_detail .hv-open');
  assert.strictEqual(filterDemo.d.getElementById('hv_id').value,candidate);
  assert.deepStrictEqual(filterDemo.errors,[]);
  console.log('PASS demo_dom_regression: source templates, intersected section filters, periods, counts, quantiles, empty states, search/sort, case evidence, focus, navigation, Data QC and suite payload identity');
}finally{opened.forEach(x=>x.window.close());fs.rmSync(output,{recursive:true,force:true});}
