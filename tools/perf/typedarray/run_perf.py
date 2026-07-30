#!/usr/bin/env python3
"""ABBA-balanced perf-stat driver for audit line P7-30.

Configurations differ only in LD_PRELOAD, never in the binary: the A/B that
isolates the process-memory probe reuses one zjs build on both sides, so build
bistability cannot enter the comparison at all.

CPU 19 sits on armv8_pmuv3_1; the events are named on that PMU explicitly so
that the armv8_pmuv3_0 rows, which perf prints as `<not counted>`, are never
opened and never parsed. L1-dcache-stores is `<not supported>` on this part and
L1-dcache-loads aliases the combined l1d_cache counter, so the read/write split
uses the raw ARMv8 events L1D_CACHE_RD (0x40) and L1D_CACHE_WR (0x41); their sum
was checked against L1-dcache-loads before use.

Must be run under `flock -x /tmp/zjs-host-heavy.lock`; it pins with taskset -c 19
itself.
"""
import json, os, statistics, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CASES = os.path.join(ROOT, 'tools', 'perf', 'typedarray', 'cases')
TMP = os.environ.get('TMPDIR', '/tmp')
N = 200000

PMU = 'armv8_pmuv3_1'
EVENTS = [
    (f'{PMU}/instructions/', 'instructions'),
    (f'{PMU}/cycles/', 'cycles'),
    (f'{PMU}/event=0x40/', 'l1d_loads'),
    (f'{PMU}/event=0x41/', 'l1d_stores'),
    ('task-clock', 'task_clock_ms'),
]

ZJS = os.path.join(ROOT, 'zig-out', 'bin', 'zjs')
QJS = '/home/aneryu/quickjs/qjs'
SHIM = os.path.join(TMP, 'probe_block.so')

CONFIGS = {
    'qjs':           (QJS, {}),
    'zjs':           (ZJS, {}),
    'zjs_probe_on':  (ZJS, {'LD_PRELOAD': SHIM, 'PROBE_BLOCK_PASSIVE': '1'}),
    'zjs_probe_off': (ZJS, {'LD_PRELOAD': SHIM}),
    # Half blocks, to separate the /proc/self/statm read from the two cgroup
    # opens. Both halves leave the engine's decision unchanged on this host:
    # rss_bytes and cgroup_limit_bytes are both consumed only by gates that the
    # default `balanced` policy disables, and the cgroup files do not exist.
    'zjs_no_statm': (ZJS, {'LD_PRELOAD': SHIM, 'PROBE_BLOCK_ONLY': 'statm'}),
    'zjs_no_cgroup': (ZJS, {'LD_PRELOAD': SHIM, 'PROBE_BLOCK_ONLY': 'cgroup'}),
}


def one(config, case):
    binary, extra = CONFIGS[config]
    env = dict(os.environ)
    env.pop('LD_PRELOAD', None)
    env.pop('PROBE_BLOCK_PASSIVE', None)
    env.pop('PROBE_BLOCK_ONLY', None)
    env.update(extra)
    cmd = ['taskset', '-c', '19', 'perf', 'stat', '-x,',
           '-e', ','.join(e for e, _ in EVENTS),
           binary, os.path.join(CASES, case + '.js')]
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f'{config} {case} failed rc={p.returncode}: {p.stderr[-2000:]}')
    vals = {}
    for line in p.stderr.splitlines():
        parts = line.split(',')
        if len(parts) < 3:
            continue
        raw, name = parts[0], parts[2]
        if raw.startswith('<'):
            continue  # the other PMU, or an unsupported event
        for ev, key in EVENTS:
            if name == ev:
                vals[key] = float(raw)
    missing = [k for _, k in EVENTS if k not in vals]
    if missing:
        raise SystemExit(f'{config} {case}: missing counters {missing}\n{p.stderr}')
    vals['stdout'] = p.stdout.strip()
    return vals


def main():
    samples = int(os.environ.get('P7_30_SAMPLES', '6'))
    if samples % 2:
        raise SystemExit('sample count must be even (an odd count has voided headline numbers twice)')
    configs = os.environ.get('P7_30_CONFIGS', 'qjs,zjs,zjs_probe_off').split(',')
    cases = sys.argv[1:]
    out = {}
    for case in cases:
        acc = {c: [] for c in configs}
        stdout = {}
        for rep in range(samples // 2):
            for order in (configs, list(reversed(configs))):
                for c in order:
                    v = one(c, case)
                    stdout.setdefault(c, v['stdout'])
                    if stdout[c] != v['stdout']:
                        raise SystemExit(f'{c} {case}: unstable stdout')
                    acc[c].append(v)
        row = {'samples': samples, 'stdout': stdout}
        for c in configs:
            med = {k: statistics.median(s[k] for s in acc[c]) for _, k in EVENTS}
            row[c] = {
                'insn': med['instructions'],
                'cycles': med['cycles'],
                'l1d_loads': med['l1d_loads'],
                'l1d_stores': med['l1d_stores'],
                'ms': med['task_clock_ms'] / 1e6,
                'insn_per_op': med['instructions'] / N,
                'cycles_per_op': med['cycles'] / N,
                'l1d_loads_per_op': med['l1d_loads'] / N,
                'l1d_stores_per_op': med['l1d_stores'] / N,
                'ns_per_op': med['task_clock_ms'] / N,
            }
        out[case] = row
        cols = '  '.join(f"{c}={row[c]['insn_per_op']:9.1f}i/{row[c]['ns_per_op']:8.1f}ns" for c in configs)
        print(f'{case:<12} {cols}', flush=True)
    dest = os.environ.get('P7_30_OUT', os.path.join(TMP, 'p7-30-perf.json'))
    prev = {}
    if os.path.exists(dest):
        with open(dest) as f:
            prev = json.load(f)
    prev.update(out)
    with open(dest, 'w') as f:
        json.dump(prev, f, indent=1)
    print('wrote', dest)


if __name__ == '__main__':
    main()
