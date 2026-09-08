"""Exercise collector CLIs with explicit process fixtures, never engine scores.

Pass a clean pinned upstream checkout for the real inventory validation.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

upstream = Path(sys.argv[1]).resolve()
tools = Path(__file__).resolve().parent
scratch = Path('.scratch/jetstream3').resolve()
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=scratch, prefix='runners-') as temp:
    root = Path(temp)
    fixture = root / 'process-fixture'
    fixture.write_text(f'#!{sys.executable}\n' + '''
import json, pathlib, subprocess, sys, time
mode = pathlib.Path(__file__).with_suffix('.mode').read_text()
name = next(arg.removeprefix('--test=') for arg in sys.argv if arg.startswith('--test='))
print(json.dumps({'JetStream3.0': {'tests': {name: {'metrics': {'Score': {'current': [1]}}}}}}), flush=True)
if mode == 'failed':
    print('EXPECTED_PROCESS_FAILURE', file=sys.stderr)
    sys.exit(7)
if mode == 'timeout':
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
    pathlib.Path(__file__).with_suffix('.pid').write_text(str(child.pid))
    time.sleep(60)
''')
    fixture.chmod(0o755)
    engines = root / 'engines.json'
    engines.write_text(json.dumps([dict(name='process-fixture', binary=str(fixture),
                                       sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(), separator=[])]))
    for runner in ('survey', 'compare'):
        for mode in ('completed', 'failed', 'timeout'):
            fixture.with_suffix('.mode').write_text(mode)
            output = root / f'{runner}-{mode}'
            args = ['--shell', str(fixture)] if runner == 'survey' else ['--engines', str(engines)]
            result = subprocess.run([sys.executable, str(tools / (runner + '.py')), *args,
                                     '--upstream', str(upstream), '--output', str(output),
                                     '--tests', 'Air', '--timeout', '1'],
                                    capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (runner, mode, result.stdout, result.stderr)
            data = json.loads((output / 'results.json').read_text())
            rows = data['results' if runner == 'survey' else 'runs']
            expected = 'completed-upstream' if mode == 'completed' and runner == 'survey' else mode
            assert len(rows) == (4 if runner == 'compare' and mode == 'completed' else 1), rows
            assert all(row['status'] == expected for row in rows), rows
            assert all(('upstreamResult' in row) == (mode == 'completed') for row in rows), rows
            assert data['aggregateScore'] is None, data
            if mode == 'failed':
                assert rows[0]['exit'] == 7, rows
                assert any('EXPECTED_PROCESS_FAILURE' in p.read_text() for p in output.glob('*.stderr'))
            if mode == 'timeout':
                child = int(fixture.with_suffix('.pid').read_text())
                # A killed child may briefly remain a zombie until reaped by init.
                stat = Path(f'/proc/{child}/stat')
                for _ in range(100):
                    try:
                        stopped = stat.read_text().rsplit(')', 1)[1].split()[0] == 'Z'
                    except FileNotFoundError:
                        stopped = True
                    if stopped:
                        break
                    import time
                    time.sleep(0.01)
                assert stopped, f'timeout left child {child} running'
            print(f'{runner} {mode}: PASS')
