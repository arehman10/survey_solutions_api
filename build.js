const fs = require('fs');
const path = require('path');
const { marked } = require('marked');
const repo = path.resolve(__dirname, '../..');
const sources = [
 ['Getting-Started','setup','Getting started'],
 ['Configuration','configuration','Configuration'],
 ['Command-Reference','commands','Commands'],
 ['Exports-and-Backups','exports','Exports & backups'],
 ['Paradata-Analysis','paradata','Paradata'],
 ['Reports-and-Data-QC','reports','Reports & Data QC'],
 ['Troubleshooting','help','Troubleshooting'],
 ['Development','development','Development'],
 ['Testing-and-Release','testing','Testing & release']
];
const slug = s => s.toLowerCase().replace(/<[^>]*>/g,'').replace(/[^\w\s-]/g,'').trim().replace(/\s+/g,'-');
const records = [];
for (const [file,category,label] of sources) {
 const source=fs.readFileSync(path.join(repo,'wiki',file+'.md'),'utf8').replace(/\r/g,'').replace('raw destructive calls require `allowdestructive`','raw `DELETE` requests require `allowdestructive`');
 const chunks = source.split(/^## /m).slice(1);
 for(const chunk of chunks) {
  const newline = chunk.indexOf('\n'), title=chunk.slice(0,newline).trim(), body=chunk.slice(newline+1).trim();
  const html=marked.parse(body);
  records.push({id:category+'-'+slug(title), category,label,title,html,file,anchor:slug(title)});
 }
}
const mappings=Object.fromEntries(sources.map(([file,category])=>[file,category]));
function link(href, current) {
 if(href.startsWith('#')) return '#reference/'+current.category+'-'+href.slice(1);
 const m=href.match(/^([A-Za-z-]+)\.md(?:#(.*))?$/);
 if(m && m[1]==='Home') return '#overview';
 if(m && mappings[m[1]]) {
  const candidate=m[2] ? records.find(r=>r.file===m[1]&&r.anchor===m[2]) : records.find(r=>r.file===m[1]);
  if(candidate) return '#reference/'+candidate.id;
  if(m[2] && records.some(r=>r.file===m[1]&&[...r.html.matchAll(/<h[3-6](?: [^>]*)?>(.*?)<\/h[3-6]>/g)].some(h=>slug(h[1])===m[2]))) return '#reference/'+mappings[m[1]]+'-'+m[2];
 }
 return href;
}
for(const record of records) {
 record.html=record.html.replace(/href="([^"]+)"/g, (_,h)=>'href="'+link(h,record)+'"');
 // Table overflow stays inside its own scroll container on small screens.
 record.html=record.html.replace(/<table>/g,'<div class="table-scroll" tabindex="0" role="region" aria-label="Reference table"><table>').replace(/<\/table>/g,'</table></div>');
 record.html=record.html.replace(/<h([3-6])>(.*?)<\/h\1>/g,(_,level,text)=>`<h${level} id="${record.category}-${slug(text)}">${text}</h${level}>`);
}
const template=fs.readFileSync(path.join(__dirname,'template.html'),'utf8');
const output=template.replace('/*__REFERENCE_DATA__*/',JSON.stringify(records).replace(/</g,'\\u003c'));
fs.writeFileSync(path.join(repo,'wiki/index.html'),output);
console.log(JSON.stringify({referenceSections:records.length,bytes:Buffer.byteLength(output)}));
