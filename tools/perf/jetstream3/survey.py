"""Bounded, isolated diagnostic survey. Never emits an aggregate score."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def completed_result(stdout, name, code, *, timed_out=False):
    if code != 0 or timed_out:
        return None
    documents=[]
    for line in stdout.splitlines():
        try:
            value=json.loads(line)
        except ValueError:
            continue
        if isinstance(value,dict) and 'JetStream3.0' in value:
            documents.append(value)
    if len(documents) != 1:
        return None
    try:
        tests=documents[0]['JetStream3.0']['tests']
        scores=tests[name]['metrics']['Score']['current']
        if set(tests)=={name} and len(scores)==1 and type(scores[0]) in (float,int) and math.isfinite(scores[0]) and scores[0]>0:
            return documents[0]
    except (KeyError, TypeError, AttributeError, OverflowError):
        return None
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--shell', required=True, type=Path)
    p.add_argument('--upstream', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--tests', help='Comma-separated pilot entries; omitted means entire manifest')
    p.add_argument('--timeout', type=float, default=60)
    a = p.parse_args()
    if not math.isfinite(a.timeout) or a.timeout <= 0:
        p.error('timeout must be positive and finite')
    a.shell = a.shell.resolve()
    a.upstream = a.upstream.resolve()
    a.output.mkdir(parents=True, exist_ok=False)
    inventory = json.loads(subprocess.check_output(['node', str(Path(__file__).with_name('inventory.mjs')), str(a.upstream)], text=True))
    (a.output/'inventory.json').write_text(json.dumps(inventory, indent=2)+'\n')
    selected = [w['name'] for w in inventory['workloads'] if w['scope'] == 'included']
    if a.tests:
        pilot = a.tests.split(',')
        if len(set(pilot)) != len(pilot) or any(t not in selected for t in pilot):
            p.error('pilot entries must be distinct members of the fixed subset')
        selected = pilot
    artifact = dict(mode='diagnostic-no-prefetch',aggregateScore=None,upstreamCommit=inventory['commit'],shellHash=sha(a.shell),timeoutSeconds=a.timeout,affinity=sorted(os.sched_getaffinity(0)),selected=selected,results=[])
    for name in selected:
        if sha(a.shell) != artifact['shellHash']:
            raise RuntimeError('Shell binary changed')
        log = a.output/(name+'.stdout')
        errors = a.output/(name+'.stderr')
        timing = (a.output/(name+'.time')).resolve()
        command = ['/usr/bin/time', '-f', '%e %M', '-o', str(timing), str(a.shell), 'cli.js', '--no-prefetch', '--dump-json-results', '--test='+name]
        with log.open('w') as out, errors.open('w') as err:
            proc = subprocess.Popen(command,cwd=a.upstream,stdout=out,stderr=err,start_new_session=True)
            timed_out = False
            try:
                code=proc.wait(timeout=a.timeout)
                status='failed' if code else 'incomplete'
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(proc.pid,signal.SIGKILL)
                except ProcessLookupError:
                    pass  # The group exited between wait timeout and kill.
                proc.wait()
                code=proc.returncode
                status='timeout'
        if sha(a.shell) != artifact['shellHash']:
            raise RuntimeError('Shell binary changed during run')
        result=dict(name=name,status=status,exit=code,command=command,stdoutSha256=sha(log),stderrSha256=sha(errors))
        # Require a single final upstream JSON result naming exactly this entry,
        # zero process exit, and a finite positive score. Printing a start line is
        # not completion. This preserves upstream checks; no extra output oracle.
        completed = completed_result(log.read_text(), name, code, timed_out=timed_out)
        if completed is not None:
            result['status']='completed-upstream'
            result['upstreamResult']=completed
        if timing.exists():
            result['processTimeRaw']=timing.read_text()
        artifact['results'].append(result)
        (a.output/'results.json').write_text(json.dumps(artifact,indent=2)+'\n')
        print(name+': '+result['status'],flush=True)


if __name__ == '__main__':
    main()
