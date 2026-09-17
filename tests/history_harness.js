'use strict';
// Execute the exact emitted worker in isolation, with real Blob slice reads.
// No DOM, network, or alternate parser implementation is involved.
const fs=require('fs');
function sourceFrom(path){
  const rows=fs.readFileSync(path,'utf8').split(/\r?\n/),out=[];let on=false;
  for(const line of rows){const b=line.indexOf('`"'),e=line.lastIndexOf('"\'');if(b<0||e<b)continue;
    const s=line.slice(b+2,e);if(s.startsWith('/* suso raw history viewer'))on=true;
    if(!on)continue;if(s.startsWith('</script>'))break;out.push(s);}
  if(!out.length)throw Error('Missing history viewer source');return out.join('\n');
}
function worker(path,replacements=[]){
  let source=sourceFrom(path);for(const [a,b] of replacements){if(!source.includes(a))throw Error('Missing test override: '+a);source=source.replace(a,b);}
  const messages=[],listeners=new Set(),self={postMessage(m){messages.push(m);for(const f of [...listeners])f();}};
  const code=new Function('self',source+"\nreturn {core:HCore,sections:typeof HSections==='undefined'?null:HSections,main:historyWorkerMain};")(self);code.main();
  function wait(type,start=0,ms=20000){return new Promise((resolve,reject)=>{
    let timer;const inspect=()=>{const m=messages.slice(start).find(x=>x.type===type||x.type==='error');if(!m)return;
      clearTimeout(timer);listeners.delete(inspect);if(m.type==='error'&&type!=='error')reject(Error(m.message));else resolve(m);};
    timer=setTimeout(()=>{listeners.delete(inspect);reject(Error('Worker timeout waiting for '+type));},ms);listeners.add(inspect);inspect();
  });}
  return {core:code.core,sections:code.sections,messages,post(data){self.onmessage({data});},wait,
    request(data,type='ready',ms=20000){const n=messages.length;self.onmessage({data});return wait(type,n,ms);}};
}
module.exports={sourceFrom,worker};
