#!/usr/bin/env python3
"""Collect per-case allocation / arena / memory-probe counts for P7-30.

No timing here and no host lock: this pass only counts, so it does not need the
exclusive lock the campaign reserves for sampling.
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CASES = os.path.join(ROOT, 'tools', 'perf', 'typedarray', 'cases')
TMP = os.environ.get('TMPDIR', '/tmp')
N = 200000

ENGINES = {
    'zjs': os.path.join(ROOT, 'zig-out', 'bin', 'zjs'),
    'qjs': '/home/aneryu/quickjs/qjs',
}
SHIMS = {
    'alloc': (os.path.join(TMP, 'alloc_counter.so'), 'ALLOC_COUNTER_OUT'),
    'arena': (os.path.join(TMP, 'arena_counter.so'), 'ARENA_COUNTER_OUT'),
    'probe': (os.path.join(TMP, 'probe_block.so'), 'PROBE_BLOCK_OUT'),
}


def run(engine, case, shim):
    so, var = SHIMS[shim]
    out = os.path.join(TMP, f'count_{engine}_{case}_{shim}.json')
    env = dict(os.environ, LD_PRELOAD=so, **{var: out})
    if shim == 'probe':
        env['PROBE_BLOCK_PASSIVE'] = '1'
    p = subprocess.run([ENGINES[engine], os.path.join(CASES, case + '.js')],
                       env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f'{engine} {case} failed: {p.stderr}')
    with open(out) as f:
        return p.stdout.strip(), json.load(f)


def main():
    cases = sys.argv[1:] or [f[:-3] for f in sorted(os.listdir(CASES))]
    rows = {}
    for case in cases:
        row = {}
        stdout = {}
        for engine in ENGINES:
            stdout[engine], alloc = run(engine, case, 'alloc')
            _, arena = run(engine, case, 'arena')
            _, probe = run(engine, case, 'probe')
            row[engine] = {
                'malloc': alloc['malloc'],
                'malloc_bytes': alloc['malloc_bytes'],
                'free': alloc['free'],
                'memset_calls': alloc['memset_calls'],
                'memset_bytes': alloc['memset_bytes'],
                'arena_alloc': arena['arena_alloc_total'],
                'arena_free': arena['arena_free_total'],
                'rss_probe_calls': probe['statm'],
                'cgroup_probe_calls': probe['cgroup_v2'] + probe['cgroup_v1'],
                'per_op': {
                    'malloc': alloc['malloc'] / N,
                    'malloc_bytes': alloc['malloc_bytes'] / N,
                    'memset_bytes': alloc['memset_bytes'] / N,
                    'arena_events': (arena['arena_alloc_total'] + arena['arena_free_total']) / (2 * N),
                    'rss_probes': probe['statm'] / N,
                },
            }
        row['stdout_agrees'] = stdout['zjs'] == stdout['qjs']
        row['stdout'] = stdout['zjs']
        rows[case] = row
        pe = row['zjs']['per_op']
        qe = row['qjs']['per_op']
        print(f"{case:<12} zjs mallocs/op {pe['malloc']:7.4f} arena/op {pe['arena_events']:7.4f} "
              f"probes/op {pe['rss_probes']:7.4f} | qjs mallocs/op {qe['malloc']:7.4f} "
              f"arena/op {qe['arena_events']:7.4f} | same output {row['stdout_agrees']}")
    out = os.path.join(TMP, 'p7-30-counts.json')
    with open(out, 'w') as f:
        json.dump(rows, f, indent=1)
    print('wrote', out)


if __name__ == '__main__':
    main()
