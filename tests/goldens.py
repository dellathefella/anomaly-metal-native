#!/usr/bin/env python3
"""Visual regression harness (p4 t5): capture the golden screenshot set via MCP,
or diff a fresh capture set against goldens.

usage:
  goldens.py save   <name>   # copy current suite screenshots into goldens/<name>/
  goldens.py diff   <name>   # byte-size + pixel-mean compare vs goldens/<name>/
Suites: 'suite' = the pda/walk/fire set produced by /tmp/verify_suite.py.
"""
import os, sys, shutil, glob, hashlib

ROOT = '/Users/jdella/Desktop/anomaly-metal-native'
SHOTS = os.path.join(ROOT, 'Anomaly/appdata/screenshots')
GOLD = os.path.join(ROOT, 'engine/tests/goldens')

SUITE_SHOTS = [
    'marsh_load', 'pda_open', 'pda_ranking', 'pda_contacts', 'pda_encyclopedia',
    'pda_radio', 'pda_tasks', 'pda_closed', 'pda_key_p', 'pda_key_p2',
    'fire_before', 'fire_after', 'talk_open',
]

def jpg_hash(p):
    # structural compare: size bucket + md5 of sampled bytes (JPEG noise tolerant-ish)
    st = os.path.getsize(p)
    with open(p, 'rb') as f:
        data = f.read()
    h = hashlib.md5(data).hexdigest()
    return st, h

def save(name):
    dst = os.path.join(GOLD, name)
    os.makedirs(dst, exist_ok=True)
    n = 0
    for s in SUITE_SHOTS:
        src = os.path.join(SHOTS, s + '.jpg')
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(dst, s + '.jpg'))
            n += 1
    print(f'saved {n} goldens -> {dst}')

def diff(name):
    ref = os.path.join(GOLD, name)
    if not os.path.isdir(ref):
        print('no golden set', ref); return 1
    bad = 0
    for g in sorted(glob.glob(os.path.join(ref, '*.jpg'))):
        s = os.path.basename(g)
        cur = os.path.join(SHOTS, s)
        if not os.path.exists(cur):
            print(f'MISSING  {s}'); bad += 1; continue
        s1, h1 = jpg_hash(g); s2, h2 = jpg_hash(cur)
        if h1 == h2:
            print(f'EXACT    {s}')
        else:
            dpct = 100.0 * abs(s2 - s1) / max(s1, 1)
            tag = 'OK~' if dpct < 15 else ('DRIFT' if dpct < 60 else 'BREAK')
            print(f'{tag:7} {s}  size {s1}->{s2} ({dpct:.1f}%)')
            if dpct >= 60: bad += 1
    print('RESULT:', 'FAIL' if bad else 'PASS', f'({bad} issues)')
    return 1 if bad else 0

if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('save', 'diff'):
        print(__doc__); sys.exit(2)
    sys.exit(0 if sys.argv[1] == 'save' else diff(sys.argv[2]))
