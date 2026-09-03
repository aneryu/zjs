#!/usr/bin/env python3
"""Aggregate docs/reports/tgc-r3/runs/*.stdout census sections into markdown."""
import re, sys, glob, os, collections
runs = sorted(glob.glob(sys.argv[1] if len(sys.argv) > 1 else 'docs/reports/tgc-r3/runs/*.stdout'))
rows = []
keys = collections.Counter()
by_src = collections.Counter(); by_ptr = collections.Counter(); by_kind = collections.Counter(); regs = collections.Counter()
for path in runs:
    name = os.path.basename(path)[:-7]
    txt = open(path).read()
    err = open(path[:-6]+'stderr').read()
    wall = re.search(r'wall=([\d.]+) rss=(\d+)', err)
    m = re.search(r'census probes (\d+), direct (\d+) \(young (\d+)\), transitive (\d+), dropped keys (\d+)', txt)
    minors = re.search(r'gc: minor collections (\d+)', txt)
    majors = re.search(r'major completed (\d+)', txt)
    precise = sum(int(x) for x in re.findall(r'\((\d+) precise,', err))
    consv = sum(int(x) for x in re.findall(r'precise, (\d+) conservative-only\)', err))
    exit_code = re.search(r'exit=(\d+)', txt)
    if not m:
        rows.append((name, exit_code.group(1) if exit_code else '?', '-', '-', '-', '-', '-', '-', precise, consv, wall.group(1) if wall else '-'))
        continue
    probes, direct, young, trans, dropped = map(int, m.groups())
    rows.append((name, exit_code.group(1) if exit_code else '?', minors.group(1) if minors else '-', majors.group(1) if majors else '-', probes, direct, young, trans, precise, consv, wall.group(1) if wall else '-'))
    s = re.search(r'by source registers (\d+), stack<1K (\d+), <4K (\d+), <16K (\d+), <64K (\d+), >=64K (\d+); by pointer exact (\d+), prefix (\d+), interior (\d+)', txt)
    if s:
        for k, v in zip(['registers','stack<1K','stack<4K','stack<16K','stack<64K','stack>=64K'], s.groups()[:6]): by_src[k] += int(v)
        for k, v in zip(['exact','prefix','interior'], s.groups()[6:]): by_ptr[k] += int(v)
    k = re.search(r'by kind (.*)', txt)
    if k:
        parts = k.group(1).split()
        for i in range(0, len(parts), 2): by_kind[parts[i]] += int(parts[i+1])
    r = re.search(r'conservative-only registers (.*)', txt)
    if r and r.group(1).strip() != 'none':
        parts = r.group(1).split()
        for i in range(0, len(parts), 2): regs[parts[i]] += int(parts[i+1])
    for line in re.findall(r'conservative-only #\d+ (\d+) fn=(\S+) kind=(\S+) class=(\d+) src=(\S+) ptr=(\S+) young=(\d) native=(\d)', txt):
        cnt, fn, kind, cls, src, ptr, yg, nat = line
        keys[(fn, kind, cls, src, ptr, yg, nat, name)] += int(cnt)
print('| load | exit | minors | majors | probes | direct | direct young | transitive | precise violations | conservative-only violations | wall s |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for r in rows: print('| ' + ' | '.join(str(x) for x in r) + ' |')
tot = lambda i: sum(r[i] for r in rows if isinstance(r[i], int))
print(f'\nTotals: probes {tot(4)}, direct {tot(5)} (young {tot(6)}), transitive {tot(7)}, precise violations {tot(8)}, conservative-only violations {tot(9)}\n')
print('By source: ' + ', '.join(f'{k} {v}' for k, v in by_src.items()))
print('By pointer: ' + ', '.join(f'{k} {v}' for k, v in by_ptr.items()))
print('By kind: ' + ', '.join(f'{k} {v}' for k, v in by_kind.items() if v))
print('Registers: ' + ', '.join(f'{k} {v}' for k, v in regs.most_common()))
print('\nTop 25 (function, kind, class, source, pointer, young, native, load):\n')
print('| # | hits | function | kind | class | source | pointer | young | native | load |')
print('|---|---|---|---|---|---|---|---|---|---|')
for i, (k, v) in enumerate(keys.most_common(25), 1):
    print(f'| {i} | {v} | `{k[0]}` | {k[1]} | {k[2]} | {k[3]} | {k[4]} | {k[5]} | {k[6]} | {k[7]} |')
