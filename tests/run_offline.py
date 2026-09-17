#!/usr/bin/env python3
"""Run the exact-source JS regression suites without Stata or a server."""
import argparse, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--source',type=Path,default=ROOT/'suso.ado')
ap.add_argument('--dom',action='store_true',help='also run jsdom interactions; requires npm install in tests/')
args=ap.parse_args()
node=shutil.which('node')
if not node: raise SystemExit('Node.js is required for the offline JavaScript suites.')
source=str(args.source.resolve())
dom_names={'demo_dom_regression.js','suite_layout_regression.js'}
paths=sorted((ROOT/'tests'/'baseline').glob('*.js'))
paths+=sorted(p for p in (ROOT/'tests').glob('*regression*.js') if p.name not in dom_names)
cases=[(p,source) for p in paths]
failed=[]
with tempfile.TemporaryDirectory(prefix='suso-regression-preview-') as preview:
    if args.dom:
        cases.append((ROOT/'tests'/'demo_dom_regression.js',source))
        layout=ROOT/'tests'/'suite_layout_regression.js'
        if layout.exists():
            subprocess.run([sys.executable,str(ROOT/'tools'/'render_demo.py'),'--source',source,'--out',preview],check=True,cwd=ROOT,stdout=subprocess.DEVNULL)
            cases.append((layout,preview))
    for p,target in cases:
        print('\nRUN '+str(p.relative_to(ROOT)),flush=True)
        result=subprocess.run([node,str(p),target],cwd=ROOT)
        if result.returncode:failed.append(p.name)
print('\n'+('FAIL: '+', '.join(failed) if failed else f'PASS: {len(cases)} offline JavaScript suites'))
print('Stata/SFI and actual .dta report generation are outside this runner.')
sys.exit(bool(failed))
