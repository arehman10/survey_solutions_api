#!/usr/bin/env python3
"""Deterministic, artificial SuSo raw inputs for the licensed-Stata example."""
from pathlib import Path
import csv, datetime as dt, html
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'examples'/'synthetic'

def build():
    OUT.mkdir(parents=True,exist_ok=True)
    events=[]; final=[]
    names=['Amina Khan','Bilal Ahmed','Chandra Silva']
    qspec=[('has_employees','Does the business have permanent employees?',''),('employees','How many permanent employees worked here last month?','has_employees==1'),('sales','What were total sales last month?','')]
    qspec += [(f'q{i:02d}',f'Synthetic operating characteristic {i} (numeric demonstration item)','') for i in range(1,31)]
    for n in range(1,19):
        iid=f'00000000-0000-0000-0000-{n:012d}'; actor=names[(n-1)//6]
        stamp=dt.datetime(2026,9,4,23 if n==2 else 9+(n%6),0,0)
        order=0
        def add(event, parameters='', delta=1, responsible=None, role='Interviewer'):
            nonlocal stamp,order
            stamp+=dt.timedelta(seconds=delta); order+=1
            events.append([iid,order,event,responsible or actor,role,stamp.isoformat(timespec='milliseconds'),'+00:00',parameters])
        add('InterviewCreated'); add('InterviewModeChanged','CAPI||'); add('Resumed','Tablet')
        for v,_,_ in qspec:
            value=1 if v=='has_employees' else 8 if v=='employees' else 250000+n*1000 if v=='sales' else n
            add('AnswerSet',f'{v}||{value}||',delta=1 if n==1 else 45+n)
        if n in (3,7,13):
            add('AnswerSet','has_employees||0||',delta=25)
            add('AnswerRemoved','employees||')
            if n != 13: add('AnswerSet','has_employees||1||',delta=15)
        if n==5:
            add('Paused','Tablet',delta=1)
            add('Resumed','Tablet',delta=1800,responsible=names[1])
            for i in range(11,31): add('AnswerSet',f'q{i:02d}||{n+1}||',responsible=names[1])
        add('Completed',responsible=names[1] if n==5 else None)
        if n%4==0: add('ApproveBySupervisor',delta=600,responsible='Synthetic supervisor',role='Supervisor')
        row=dict(interview__id=iid,interview__key=f'00-00-00-{n:02d}',assignment__id=100+n,interview__status=120 if n%4==0 else 100,region=1 if n%2 else 2,has_employees=0 if n==13 else 1,employees=-9 if n in (3,7) else '' if n==13 else 8,sales=250000+n*1000)
        row.update({f'q{i:02d}':n+1 if n==5 and i>=11 else n for i in range(1,31)})
        final.append(row)
    with (OUT/'paradata.tab').open('w',encoding='utf-8',newline='') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n',quoting=csv.QUOTE_NONE)
        w.writerow(['interview__id','order','event','responsible','role','timestamp_utc','tz_offset','parameters']);w.writerows(events)
    with (OUT/'final-data.csv').open('w',encoding='utf-8',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(final[0]),lineterminator='\n');w.writeheader();w.writerows(final)
    out=['<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>SYNTHETIC questionnaire</title></head><body><h1>Synthetic example only</h1><section class="section"><div class="section_header"><h2 id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">Synthetic establishment survey</h2></div>']
    for i,(v,text,condition) in enumerate(qspec,1):
        gate=f'<div class="condition"><span>E</span>{html.escape(condition)}</div>' if condition else ''
        out.append(f'<div class="question-container"><div class="question"><div class="question-title" id="{i:032x}">{html.escape(text)}</div><div class="common-info">{gate}</div></div><div class="answer"><div class="question-meta"><div class="type">numeric: integer</div><div class="variable_name">{v}</div></div><div class="answer-editor"><input type="number" class="dashes"></div></div></div>')
    out.append('</section></body></html>')
    (OUT/'questionnaire.html').write_text('\n'.join(out)+'\n',encoding='utf-8')
    print(f'Synthetic fixtures: {len(final)} interviews, {len(events)} events, {len(qspec)} questions')
if __name__=='__main__':build()
