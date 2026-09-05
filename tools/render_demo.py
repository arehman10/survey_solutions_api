#!/usr/bin/env python3
"""Render real ADO HTML/JS writers with synthetic inputs, without emulating Stata.

This is a source-template preview, NOT a Stata-generated analytical result. A
strict, limited expression reader evaluates only string-card assembly; statistical
payloads are explicitly illustrative. Unknown source constructs fail rather than
silently rendering an inaccurate replacement.
"""
from __future__ import annotations
import argparse, csv, datetime as dt, hashlib, html, json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def between(text, start, end, include_end=False):
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b + (len(end) if include_end else 0)]


def program(src, name):
    m = re.search(r'^program ' + re.escape(name) + r'\b.*?^end\s*$', src, re.M | re.S)
    if not m:
        raise ValueError('Missing program ' + name)
    return m.group()


def number(n):
    return str(int(n)) if isinstance(n, (int, float)) and n == int(n) else str(n)


def stata_string(n, fmt=''):
    if fmt.startswith('%td'):
        return (dt.datetime(1960, 1, 1) + dt.timedelta(days=n)).strftime('%d %b %Y')
    if fmt.startswith('%tc'):
        d = dt.datetime(1960, 1, 1) + dt.timedelta(milliseconds=n)
        return d.strftime('%H:%M') if fmt == '%tcHH:MM' else d.strftime('%Y-%m-%d %H:%M:%S')
    return number(n)


# Whitelisted subset of Stata expressions used by h_card/e_* string assembly.
class Expr:
    pattern = re.compile(r'\s*(?:`"(.*?)"\'|"([^"]*)"|(\d+(?:\.\d+)?)|([A-Za-z_][A-Za-z_0-9]*)|(==|!=|>=|<=|[+*/(),!&|<>?:\[\]-]))', re.S)
    precedence = {'|': 1, '&': 2, '==': 3, '!=': 3, '<': 3, '>': 3, '<=': 3, '>=': 3, '+': 4, '-': 4, '*': 5, '/': 5}
    def __init__(self, s, env):
        self.env = env
        self.tokens = []
        pos = 0
        while pos < len(s.strip()):
            m = self.pattern.match(s, pos)
            if not m:
                raise ValueError('Unsupported expression at ' + repr(s[pos:pos + 100]))
            if m[1] is not None or m[2] is not None:
                self.tokens.append(('str', m[1] if m[1] is not None else m[2]))
            elif m[3] is not None:
                self.tokens.append(('num', float(m[3])))
            elif m[4] is not None:
                self.tokens.append(('id', m[4]))
            else:
                self.tokens.append(('op', m[5]))
            pos = m.end()
        self.i = 0
    def pop(self):
        t = self.tokens[self.i]; self.i += 1; return t
    def peek(self):
        return self.tokens[self.i][1] if self.i < len(self.tokens) else None
    def parse(self, minimum=0):
        typ, x = self.pop()
        if x in ('!', '-') and typ == 'op':
            v = self.parse(6); v = not v if x == '!' else -v
        elif x == '(' and typ == 'op':
            v = self.parse(); assert self.pop()[1] == ')'
        elif typ in ('str', 'num'):
            v = x
        elif typ == 'id':
            if self.peek() == '(':
                self.pop(); args = []
                while self.peek() != ')':
                    args.append(self.parse())
                    if self.peek() != ',': break
                    self.pop()
                assert self.pop()[1] == ')'
                functions = {'char': lambda n: chr(int(n)), 'strofreal': number, 'string': stata_string,
                             'cond': lambda c, a, b: a if c else b, 'missing': lambda x: x is None or x == '',
                             'length': len, 'substr': lambda s, a, n: s[int(a)-1:int(a)-1+int(n)],
                             'subinstr': lambda s, a, b, n: s.replace(a, b, int(n)),
                             'ustrlower': lambda s: s.lower(), 'strtrim': lambda s: s.strip()}
                if x not in functions: raise ValueError('Unsupported function ' + x)
                v = functions[x](*args)
            else:
                if x not in self.env: raise ValueError('Missing source input: ' + x)
                v = self.env[x]
                if self.peek() == '[':  # Preview is one synthetic row at a time.
                    self.pop(); self.parse(); assert self.pop()[1] == ']'
        else:
            raise ValueError('Unexpected token ' + repr((typ, x)))
        while self.peek() in self.precedence and self.precedence[self.peek()] >= minimum:
            op = self.pop()[1]; b = self.parse(self.precedence[op] + 1)
            if op == '+': v = v + b
            elif op == '-': v = v - b
            elif op == '*': v = v * b
            elif op == '/': v = v / b
            elif op == '&': v = bool(v) and bool(b)
            elif op == '|': v = bool(v) or bool(b)
            elif op == '==': v = v == b
            elif op == '!=': v = v != b
            elif op == '>': v = v > b
            elif op == '<': v = v < b
            elif op == '>=': v = v >= b
            elif op == '<=': v = v <= b
        if minimum == 0 and self.peek() == '?':
            self.pop(); yes = self.parse(); assert self.pop()[1] == ':'
            no = self.parse(); v = yes if v else no
        return v
    def value(self):
        out = self.parse()
        if self.i != len(self.tokens): raise ValueError('Unconsumed expression tokens')
        return out


def expr(s, env):
    return Expr(s.strip(), env).value()


def logical_lines(s):
    return re.sub(r'///\s*\n\s*', ' ', s).splitlines()


def assignments(source, env):
    for raw in logical_lines(source):
        line = raw.strip()
        m = re.match(r'quietly (?:gen\s+\w+|replace)\s+(\w+)\s*=\s*(.*)', line)
        if not m: continue
        # ' if ' is outside quoted literals in the card expressions.
        parts = re.split(r' if (?=(?:[^"]*"[^"]*")*[^"]*$)', m[2], maxsplit=1)
        if len(parts) == 2 and not expr(parts[1], env):
            env.setdefault(m[1], ''); continue
        env[m[1]] = expr(parts[0], env)
    return env


class Renderer:
    def __init__(self, src, macros):
        self.src, self.macros = src, macros
    def subst(self, s, local=None):
        env = self.macros | (local or {})
        def replace(m):
            if m[1] not in env: raise ValueError('Unprovided template macro ' + m[1])
            return str(env[m[1]])
        return re.sub(r"`([A-Za-z_][A-Za-z_0-9]*)'", replace, s)
    def writes(self, block, local=None, row=None):
        out = []
        env = (row or {}) | {'i': 1}
        for line in logical_lines(block):
            if 'file write ' not in line: continue
            if row is not None and line.strip().startswith('if '):
                condition = line.strip()[3:line.strip().index('file write')].strip()
                if not expr(self.subst(condition, local), env): continue
            m = re.search(r"file write `\w+'\s+(.*)", line)
            if not m: continue
            rhs = m[1].strip()
            if rhs == '_n':
                out.append('\n'); continue
            newline = rhs.endswith(' _n')
            if newline: rhs = rhs[:-3].rstrip()
            # file write alternates compound quoted literals and parenthesized expressions.
            pos = 0; parts = []
            while pos < len(rhs):
                while pos < len(rhs) and rhs[pos].isspace(): pos += 1
                if rhs.startswith('`"', pos):
                    end = rhs.index('"\'', pos + 2)
                    parts.append(self.subst(rhs[pos + 2:end], local)); pos = end + 2
                elif rhs[pos] == '(':
                    level = 1; end = pos + 1; quoted = False
                    while end < len(rhs) and level:
                        c = rhs[end]
                        if c == '"': quoted = not quoted
                        if not quoted:
                            level += (c == '(') - (c == ')')
                        end += 1
                    if row is None: raise ValueError('Dynamic writer requires row: ' + line)
                    parts.append(number(expr(self.subst(rhs[pos + 1:end - 1], local), env))); pos = end
                else:
                    raise ValueError('Unknown file-write token: ' + rhs[pos:])
            out.append(''.join(parts) + ('\n' if newline else ''))
        return ''.join(out)
    def js(self, name):
        p = program(self.src, name)
        out = ''
        for line in p.splitlines():
            if 'file write ' in line: out += self.writes(line)
            else:
                m = re.match(r'\s*(_suso_para_\w+_js)\s+`\w+\'', line)
                if m: out += self.js(m[1])
        return out
    def suite(self, panes):
        p = re.search(r'^void _suso_suite_write\(.*?^\}', self.src, re.M | re.S).group()
        pane_src = re.search(r'^void _suso_suite_pane\(.*?^\}', self.src, re.M | re.S).group()
        out = ''
        env = {'title': 'Paradata review — synthetic example', 'sub': 'SYNTHETIC ILLUSTRATION · 04 Sep 2026 · no real interviews'}
        for line in p.splitlines():
            m = re.search(r'_suso_suite_pane\(fh, ([123]),', line)
            if m:
                k = int(m[1]); pe = env | {'k': k, 'disp': 'block' if k == 1 else 'none'}
                for pl in pane_src.splitlines():
                    if 'else fwrite' in pl: continue
                    pm = re.search(r'fwrite\(fh, (.*)\)', pl)
                    if not pm: continue
                    if '_suso_suite_esc(' in pm[1]: out += html.escape(panes[k], quote=True).replace('&#x27;', "'")
                    else: out += str(expr(pm[1], pe))
                continue
            m = re.search(r'fwrite\(fh, (.*)\)', line)
            if m: out += str(expr(m[1], env))
        return out


def j(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')


def fixture():
    base = dict(id='',k='',a='',r='',le='',fi='',na=1,ho=0,pas=1,ws='Completed',wsp='Completed',wsd='Completed',wss='data',wsc='completed',wsm=0,d0='2026-09-04',d1='2026-09-04',m=0,mm=0,mu=0,tq=1,lq=1,itq=1,ilq=1,im=0,imm=0,imu=0,itz=0,ito=0,cb=0,nt=30,ntt=30,nc=1,act=32,af=32,paf=32,pact=32,sp=40,spf=40,lp=0,lpp=0,wd=1,wdt=1,on=0,pr=0,med=12,fsh=0.03,nsh=0,ch=0,cas=0,rem=0,wip=0,cop=0,cr=0,cu=0,fda=0,fad=0,feb=0,fbe=0,flu=0,fnd=0,fck=0,fdc=1,fr=1,rt=1,ov=0,ovt=0,ova='',ovd='',rj=0,rb=None,rq=None,re=None,ref=None,rba='',rbv='',rbc=0,rbb=0,pc=0,pca=0,pcn=0,pco=0,pcf=0,pcno=0,pcd='',ve=0,nq=30,pq=30,pans=30,pansf=30,pss=1,ss=1,sf=1,sr=0,rs=0,tz=0,to=0)
    rows = []; actors = []; names = ['Amina Khan', 'Bilal Ahmed', 'Chandra Silva']
    for n in range(1,19):
        a = names[(n-1)//6]; status = 'Completed' if n % 4 else 'SupervisorApproved'; klass = 'completed' if n % 4 else 'approvebysup'
        hour = 10 + n % 5; h = [0]*24; h[hour] = 30
        g = [0]*41; g[24] = 30
        r = base | dict(id=f'00000000-0000-0000-0000-{n:012d}',k=f'00-00-00-{n:02d}',a=str(100+n),r=a,le=a,fi=a,ws=status,wsp=status,wsd=status,wsc=klass,f={'region': '1' if n%2 else '2'},h=h,g=g,act=28+n,af=28+n,paf=28+n,pact=28+n)
        if n == 1:
            g=[0]*41; g[1]=26; g[8]=4
            r.update(act=3,af=3,paf=3,pact=3,med=1.2,rt=.1,fr=12,fsh=26/30,g=g)
        if n == 2:
            h=[0]*24; h[23]=30; r.update(h=h,nsh=1)
        if n in (3,7,13):
            r.update(rem=1,wip=1,fck=1 if n !=13 else 0,fbe=1 if n !=13 else 0,feb=1 if n==13 else 0)
        rows.append(r)
        actors.append(dict(id=r['id'],r=a,p=1,f=1,l=1,ans=30,ansf=30,q=30,ss=1,share=1,act=r['act'],af=r['af'],nt=30,med=r['med'],fsh=r['fsh'],nsh=r['nsh'],ch=0,rt=r['rt'],fr=r['fr'],ov=0,ovd='',tq=1,lq=1,m=0,mm=0,mu=0,tz=0,to=0,h=r['h'],g=r['g']))
    # A secondary actor has a distinct risk signal; all-actor review must retain it.
    r=rows[4]; r.update(na=2,ho=1,pas=.6,le=names[1],ntt=50)
    g=[0]*41; g[1]=20; h=[0]*24; h[23]=20
    actors.append(dict(actors[4],r=names[1],p=0,f=0,l=1,ans=20,ansf=20,q=20,ss=1,share=.4,act=1,af=1,nt=20,med=1,fsh=1,nsh=1,rt=.08,fr=20,h=h,g=g))
    cases=[]
    for n, actor in [(3,names[0]),(7,names[1]),(13,names[2])]:
        r=rows[n-1]; resolved=n==13
        cases.append(dict(ak=actor.lower(),an=actor,gk='direct:has_employees',gl='Direct questionnaire relationship: has_employees',id=r['id'],ws=r['ws'],wc=r['wsc'],t='C' if resolved else 'V',q=1,need=0 if resolved else 1,re=0,ev=1,cp=0,tu=0,cev=0,out=1,key=r['k'],number=n))
    dims=[dict(v='region',vals=[dict(c='1',l='North',n=9),dict(c='2',l='South',n=9)])]
    meta=dict(fastsecs=2,gapmins=30,tzmode='device',lite=0,hasve=0,hascawi=0,haskey=1,hq='',hasassignment=1,fdims=dims)
    questions=[('has_employees','Does the business have permanent employees?','Employment',''),('employees','How many permanent employees worked here last month?','Employment','has_employees == 1'),('sales','What were total sales last month?','Sales','')]
    q=[]; aq=[]
    for status in ('','Completed','SupervisorApproved','APP'):
        pool=[r for r in rows if not status or r['ws']==status or status=='APP' and r['wsc']=='approvebysup']
        for o,(v,*_) in enumerate(questions,1):
            q.append(dict(s=status,v=v,o=o,n=len(pool),ni=len(pool),nt=len(pool),med=12,p90=18,fsh=.05))
            for a in names:
                count=sum(r['r']==a for r in pool)
                if count: aq.append(dict(q[-1],r=a,k=a.lower(),n=count,ni=count,nt=count))
    rem=[dict(a=c['an'],k=c['ak'],t='has_employees',id=c['id'],ws=c['ws'],wc=c['wc'],cp=c['cp'],tu=0,cev=0,out=1,n=1,q=1,ra=0,ck=c['need'],tier=c['t']) for c in cases]
    data=dict(meta=meta,rows=rows,actors=actors,q=q,aq=aq,rem=rem,daily=[dict(r=a,d='2026-09-04',c=sum(x['ans'] for x in actors if x['r']==a)) for a in names])
    # Compact section timing is illustrative, with exact per-actor totals.
    data['meta']['hassections']=1
    data['sections']=[dict(id=0,label='Unmapped activity'),dict(id=1,label='Employment'),dict(id=3,label='Sales'),dict(id=4,label='Business costs'),dict(id=5,label='Finance')]
    data['sq']=[['has_employees',1],['employees',1],['sales',3],['costs',4]]
    data['sa']=[];data['st']=[]
    positions={r['id']:i for i,r in enumerate(rows)}
    for ai,a in enumerate(actors):
        ri=positions[a['id']]
        data['sa'].append([ri,a['r'],a['r'].lower()])
        total=a['af']*60
        rework=180 if ri in (2,6,12) else 0
        a['act']=a['af']+rework/60
        shares=[(1,.35),(3,.45),(4,.18),(0,.02)]
        for sid,share in shares:
            data['st'].append([ai,sid,round(total*share,3),rework if sid==3 else 0,8 if sid else 1,3 if rework and sid==3 else 0,0,0])
    for r in rows:
        r['af']=sum(a['af'] for a in actors if a['id']==r['id'])
        r['act']=sum(a['act'] for a in actors if a['id']==r['id'])
    dqrows=[]
    for v,question,section,condition in questions:
        im = 2 if v=='employees' else 0
        dqrows.append(dict(v=v,st='evaluated' if condition else 'always on',s=section,t='Numeric',q=question,e=condition,bv='',on=17 if condition else 18,und=0,vu=0,vi=0,im=im,bd=0,sh=im/17,ons=[13 if condition else 14,4],uns=[0,0],vus=[0,0],vis=[0,0],ims=[im,0],bds=[0,0],fv={'region':{'1':[8 if condition else 9,0,0,0,im,0],'2':[9,0,0,0,0,0]}}))
    dq=dict(meta=dict(statuses=[dict(c=100,l='Completed',n=14),dict(c=120,l='SupervisorApproved',n=4)],fdims=dims),rows=dqrows)
    return data, cases, dq, questions


def card_inputs(c):
    resolved=c['t']=='C'; stamp=(dt.datetime(2026,9,4,10,20)-dt.datetime(1960,1,1)).total_seconds()*1000
    return dict(tier=c['t'],h_key=c['key'],h_iid=c['id'],h_ac=c['an'],h_ws=c['ws'],h_links='',h_eventstatus='Changed answer',h_event='has_employees: 1 → 0',h_qt='Does the business have permanent employees?',h_finalevent='has_employees = '+('0' if resolved else '1'),h_tg='has_employees',nlinked_direct=1,nlinked_indirect=0,reltype=1,linkmode=1,nrem=1,nqrem=1,compact=0,timing_unknown=0,final_data_checked=1,n_final_check=c['need'],nopen=0 if resolved else 1,nunknown=0,n_final_answered=0,n_expected_blank=int(resolved),n_answered_disabled=0,n_blank_enabled=c['need'],n_logic_unknown=0,n_notindata=0,n_identityunknown=0,h_check='employees',h_sc='Employment',h_en='',h_wl='employees',wlc='employees',wl_final_answered='',wl_answered_disabled='',wl_expected_blank='employees' if resolved else '',trigger_ord=25,ts0=stamp,nreanswered=0,e_ak=c['ak'],e_ws=c['ws'],e_wc=c['wc'],e_iid=c['id'],e_ac=c['an'],e_event='has_employees: 1 → 0',e_final='has_employees = '+('0' if resolved else '1'),e_check='employees',e_hqlinks='',why='Final data: employees is blank although enabled',e_rel='Direct questionnaire relationship: has_employees',e_tg='has_employees',e_qt='Does the business have permanent employees?',e_wl='employees')


def history_fixture():
    """Illustrative raw history, including unnamed actors and later review work."""
    spec=[(0,'Resumed','Amina Khan',''),(60,'AnswerSet','Amina Khan','employees||2||'),
          (90,'AnswerDeclaredValid','','sales||'),(120,'AnswerSet','','sales||100||'),
          (150,'Paused','',''),(600,'Resumed','Amina Khan',''),
          (660,'AnswerSet','Amina Khan','employees||3||roster-2'),(720,'Completed','Amina Khan',''),
          (1000,'ReceivedByHeadquarters','',''),(1100,'CommentSet','HQ reviewer','sales||review||'),
          (1160,'CommentSet','HQ reviewer','sales||more review||'),
          (1190,'AnswerSet','','unknown_question||1||'),(1220,'AnswerDeclaredValid','','unknown_question||')]
    return [dict(order=str(i),seq=i,byte=0,event=e,responsible=a,role='3' if a=='HQ reviewer' else '1',
                 timestamp=(dt.datetime(2026,5,6,9)+dt.timedelta(seconds=t)).isoformat(timespec='milliseconds'),
                 tz='+00:00:00',parameters=p) for i,(t,e,a,p) in enumerate(spec,1)]


def render(source, output):
    src=source.read_text(encoding='utf-8'); output.mkdir(parents=True,exist_ok=True)
    data,cases,dq,questions=fixture()
    macros=dict(htitle='Paradata review — synthetic example',wst=' — SYNTHETIC EXAMPLE',now='04 Sep 2026',sub='Synthetic illustration — no real interviews',nintsc=18,nstartedc=18,ncompletedc=18,nuntouchedc=0,tothrc=10,nhist=3,nfinalcheck=2,nexpectedblank=1,nfinalanswered=0,nanswereddisabled=0,nevents=650,covline='',cascade=3,window=5,fastsecs=2,gapmins=30,rnesc='interviewer roles',veline='',qordernote='Questionnaire order is used. ',qorderbutton='Reset questionnaire order',dnote='device-local date',remsev='w',histplural='ies',nobsc=18,k_eval=1,k_nocond=2,k_noev=0,k_absent=0,dsrc='Synthetic final export',misscodes='-9',nobs=18,nraw_allroles_global=3,nraw_role_global=3,nhist_global=3,ncasc_global=0,ncompactevents_global=0)
    r=Renderer(src,macros)
    skip=program(src,'_suso_para_skips')
    for c in cases:
        env=card_inputs(c)
        assignments(between(skip,'quietly gen str12 h_class','* JSON-escape in Mata'),env)
        c['card']=env['h_card']
    sp=between(skip,'file write `hf\' `"<!DOCTYPE html>','file write `hf\' `"var SK=')
    pages={2:r.writes(sp)+'var SK='+j(dict(meta=dict(allRole=3,role=3,globalHistories=3,globalCompact=0,globalCompactEvents=0),cases=cases))+';\n'+r.js('_suso_para_skip_page_js')+'</script></body></html>'}
    behavior=program(src,'_suso_para_report')
    body=between(behavior,'file write `fh\' `"<!DOCTYPE html>','capture confirm file `"`rsdpath\'"\'')
    # Use the source's exact per-row markup and source string expressions.
    begin_cards=between(behavior,'file write `fh\' `"<div class="note">Only unresolved histories','if `nshow\'>0')
    row_markup=between(behavior,'file write `fh\' `"<div class="bremcase"','file write `fh\' `"</details></div>"\' _n',True)
    cards_html=''
    for c in cases:
        if c['t']=='C': continue
        env=card_inputs(c)
        assignments(between(behavior,'quietly gen strL e_attrs','* Generated cards retain'),env)
        assignments(between(behavior,'quietly gen strL e_eventline','file write `fh\' `"<div class="note">Only unresolved histories'),env)
        cards_html+=r.writes(row_markup,dict(i=1,nshow=2),env)
    tail=between(behavior,'file write `fh\' `"<div id="r_action_none"','_suso_para_history_js `fh\'')
    pages[1]=r.writes(body)+r.writes(begin_cards,dict(nshow=2),{})+cards_html+r.writes(tail)+r.js('_suso_para_history_js')+'<script>var D='+j(data)+';\n'+r.js('_suso_para_report_js')
    check=program(src,'_suso_para_check')
    head=between(check,'file write `hf\' `"<!DOCTYPE html>','file write `hf\' `"var D=')
    engine=between(check,'file write `hf\' `"/* suso paradata check - dynamic dashboard engine */','file close `hf\'')
    pages[3]=r.writes(head)+'var D='+j(dq)+';\n'+r.writes(engine)
    for k,name in [(1,'behaviour'),(2,'skips'),(3,'dataqc')]:
        (output/(name+'.html')).write_text(pages[k],encoding='utf-8')
    (output/'paradata-example.html').write_text(r.suite(pages),encoding='utf-8')
    # Focus the actual report view; retain its complete controls and source code.
    focused=pages[1].replace('</body>',"<script>showReviewView('s_sections');</script></body>")
    (output/'section-timing-example.html').write_text(focused,encoding='utf-8')
    history_script="<script>showReviewView('s_hist');window.susoHistoryPreview("+j(history_fixture())+",true,"+j(data['rows'][0]['id'])+");</script>"
    (output/'history-timing-example.html').write_text(pages[1].replace('</body>',history_script+'</body>'),encoding='utf-8')
    manifest=dict(source_sha256=hashlib.sha256(src.encode()).hexdigest(),source_file='suso.ado',fixture_type='SYNTHETIC ILLUSTRATION; SOURCE-TEMPLATE PREVIEW, NOT STATA EXECUTION',rows=18,actors=3,notes=['HTML, CSS, JavaScript and removal-card expressions are read from the specified ADO source using program/marker boundaries.','Dashboard payload numbers are illustrative. No survey data were loaded and no Stata statistical calculations ran.','examples/example.do regenerates a report from the separately provided synthetic raw fixtures in licensed Stata; its numbers may differ from this template preview.','No external server is configured; Headquarters links appear in real reports when configured.','Load examples/synthetic/paradata.tab into the event-history control to try local raw-file reading.'],files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in output.glob('*.html')})
    (output/'fixture_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({p.name:p.stat().st_size for p in output.glob('*.html')},indent=2))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,default=ROOT/'suso.ado')
    ap.add_argument('--out',type=Path,default=ROOT/'examples'/'preview')
    args=ap.parse_args(); render(args.source,args.out)
