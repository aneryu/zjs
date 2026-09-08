"""Initial representative cross-engine snapshot, not a performance gate."""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time
from survey import completed_result, sha

CASES = ['Air','first-inspector-code-load','json-parse-inspector',
         'json-stringify-inspector','FlightPlanner','splay','doxbee-async',
         'proxy-vue','bigint-noble-ed25519','jsdom-d3-startup','threejs']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--engines',type=Path,required=True)
    p.add_argument('--upstream',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--timeout',type=float,default=120)
    p.add_argument('--tests',help='Comma-separated members of the fixed 11, for explicit reruns')
    a=p.parse_args()
    if not math.isfinite(a.timeout) or a.timeout<=0:
        p.error('timeout must be positive and finite')
    selected=a.tests.split(',') if a.tests else CASES
    if not selected or len(set(selected))!=len(selected) or any(c not in CASES for c in selected):
        p.error('tests must be distinct members of the fixed 11')
    a.upstream=a.upstream.resolve()
    a.output=a.output.resolve()
    a.output.mkdir(parents=True,exist_ok=False)
    engines=json.loads(a.engines.read_text())
    if len({e['name'] for e in engines})!=len(engines):
        p.error('engine names must be distinct')
    inv=json.loads(subprocess.check_output(['node',str(Path(__file__).with_name('inventory.mjs')),str(a.upstream)],text=True))
    entries={w['name']:w for w in inv['workloads'] if w['scope']=='included'}
    assert all(c in entries for c in selected)
    # Verify declared resource bytes before every workload. Additional transitive
    # resources are covered by the pinned clean checkout and preparation ledger.
    resources={r['path']:r['sha256'] for c in selected for r in entries[c]['resources']}
    artifact=dict(mode='diagnostic-no-prefetch',samplesPerEngine=4,aggregateScore=None,
                  cases=selected,engines=engines,inventory=inv,affinity=sorted(os.sched_getaffinity(0)),
                  timeoutSeconds=a.timeout,started=time.time(),runs=[])
    def save():
        (a.output/'results.json').write_text(json.dumps(artifact,indent=2)+'\n')
    save()
    failed=set()
    for name in selected:
        for path,digest in resources.items():
            if sha(a.upstream/path)!=digest:
                raise RuntimeError('Resource changed: '+path)
        for round_number in range(4):
            order=engines if round_number%2==0 else list(reversed(engines))
            for e in order:
                key=(name,e['name'])
                if e.get('blockedReason') or key in failed:
                    if round_number==0:
                        artifact['runs'].append(dict(case=name,engine=e['name'],round=0,status='adapter-blocked',reason=e['blockedReason']))
                        save()
                    continue
                if sha(e['binary'])!=e['sha256']:
                    raise RuntimeError('Binary changed: '+e['name'])
                stem=f"{name}.{e['name']}.{round_number}"
                out=a.output/(stem+'.stdout'); err=a.output/(stem+'.stderr'); timing=a.output/(stem+'.time')
                cmd=['/usr/bin/time','-f','%e %M','-o',str(timing),e['binary'],*e.get('flags',[]),'cli.js',*e['separator'],
                     '--no-prefetch','--dump-json-results','--test='+name]
                started_epoch=time.time()
                start=time.monotonic()
                with out.open('w') as o,err.open('w') as er:
                    proc=subprocess.Popen(cmd,cwd=a.upstream,stdout=o,stderr=er,start_new_session=True)
                    timed_out=False
                    try:
                        code=proc.wait(timeout=a.timeout)
                    except subprocess.TimeoutExpired:
                        timed_out=True
                        try:
                            os.killpg(proc.pid,signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        code=proc.wait()
                wall=time.monotonic()-start
                if sha(e['binary'])!=e['sha256']:
                    raise RuntimeError('Binary changed during run: '+e['name'])
                doc=completed_result(out.read_text(),name,code,timed_out=timed_out)
                row=dict(case=name,engine=e['name'],round=round_number,command=cmd,exit=code,
                         status='timeout' if timed_out else 'completed' if doc else 'failed' if code else 'incomplete',
                         started=started_epoch,finished=time.time(),collectorSeconds=wall,stdoutSha256=sha(out),stderrSha256=sha(err))
                if timing.exists():
                    row['processTimeRaw']=timing.read_text()
                    parts=row['processTimeRaw'].strip().splitlines()
                    if parts and not timed_out:
                        values=parts[-1].split()
                        if len(values)==2:
                            row['processSeconds']=float(values[0]); row['maxRssKiB']=int(values[1])
                if doc:
                    row['upstreamResult']=doc
                    row['score']=doc['JetStream3.0']['tests'][name]['metrics']['Score']['current'][0]
                if row['status']!='completed':
                    failed.add(key)
                artifact['runs'].append(row); save()
                print(f"{name} {e['name']} {round_number+1}/4: {row['status']} ({wall:.2f}s)",flush=True)
        print('FINISHED '+name,flush=True)
    artifact['finished']=time.time()
    save()

if __name__=='__main__':
    main()
