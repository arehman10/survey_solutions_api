#!/usr/bin/env python3
"""Check bridge and SFI method descriptors against a known working SuSo JAR."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('reference')
p.add_argument('candidate')
a = p.parse_args()

def javap(artifact, flags):
    java = os.environ.get('SUSO_JAVA', 'java')
    return subprocess.check_output([java, '-m', 'jdk.jdeps/com.sun.tools.javap.Main',
                                   '-classpath', artifact, *flags, 'org.worldbank.suso.Stata'], text=True)

def inventory(artifact):
    api = javap(artifact, ['-public', '-s'])
    methods = sorted(re.findall(r'(public static [^\n]+)\n\s+(descriptor: [^\n]+)', api))
    code = javap(artifact, ['-p', '-c'])
    calls = sorted(set(re.findall(r'Method (com/stata/sfi/[^\s]+)', code)))
    return {'public_methods': methods, 'sfi_calls': calls}

reference = inventory(a.reference)
candidate = inventory(a.candidate)
assert reference == candidate, json.dumps({'reference': reference, 'candidate': candidate}, indent=2)
with zipfile.ZipFile(a.candidate) as jar:
    classes = [n for n in jar.namelist() if n.endswith('.class')]
    assert classes and all(n.startswith('org/worldbank/suso/') for n in classes), 'Foreign classes packaged'
    assert all(int.from_bytes(jar.read(n)[6:8], 'big') == 55 for n in classes), 'Java11 classfile version mismatch'
print('PASS: %d bridge signatures, %d SFI invocation descriptors identical; %d Java11 SuSo classes only.' %
      (len(candidate['public_methods']), len(candidate['sfi_calls']), len(classes)))
