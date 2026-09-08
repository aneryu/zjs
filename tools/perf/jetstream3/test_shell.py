"""Exercise the actual shell ABI, including exit failures. No benchmark timings."""
import pathlib
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())
scratch = pathlib.Path('.scratch/jetstream3').resolve()
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=scratch, prefix='contracts-') as temp:
    root = pathlib.Path(temp)
    (root/'lexical.js').write_text('let persisted = 41;')
    (root/'bytes').write_bytes(bytes([0, 127, 128, 255]))
    (root/'text').write_text('hello 世界\n')
    (root/'module.mjs').write_text('export const answer = 42;')
    job_failure = """
const p = Promise.resolve(1);
function C(executor) {
  executor(() => { throw Error('JOB_FAILURE'); }, () => {});
}
p.constructor = { [Symbol.species]: C };
p.then(x => x);
"""
    cases = [
        ('contracts', '''
function assert(x) { if (!x) throw Error('contract failed'); }
load('lexical.js');
assert(loadString('persisted + 1') === 42);
const r = runString('let privateValue = 7; var marker = 9;');
assert(r !== globalThis && r.Array !== Array && r.marker === 9);
assert(typeof marker === 'undefined');
assert(r.loadString('privateValue') === 7);
r.load('lexical.js'); assert(r.loadString('persisted') === 41);
assert(r.loadString('Array') === r.Array);
const bytes = new Uint8Array(read('bytes', 'binary'));
assert(bytes.length === 4 && bytes[0] === 0 && bytes[2] === 128 && bytes[3] === 255);
assert(readFile('text') === 'hello 世界\\n');
assert(arguments.length === 1 && arguments[0] === 'argument');
Promise.resolve().then(() => print('CONTRACT_OK'));
''', 0, 'CONTRACT_OK'),
        ('dynamic-import', "import('./module.mjs').then(m => { if (m.answer !== 42) throw Error('wrong module'); print('IMPORT_OK'); });", 0, 'IMPORT_OK'),
        ('handled-reject', "Promise.reject(Error('handled')).catch(() => print('HANDLED_OK'));", 0, 'HANDLED_OK'),
        ('timers', """
let order = [];
const cancelled = setTimeout(() => { throw Error('cancelled timer ran'); }, 1);
clearTimeout(cancelled);
Promise.resolve().then(() => order.push('microtask'));
setTimeout(function(arg) {
  if (arg !== 42 || this !== globalThis || order.join() !== 'microtask') throw Error('timer ordering');
  print('TIMER_OK');
}, 1, 42);
const realm = runString('var marker = 42;');
realm.setTimeout(realm.loadString('(function () { if (this.marker !== 42) throw Error("realm timer"); print("REALM_TIMER_OK"); })'), 1);
let ticks = 0;
const interval = setInterval(() => { if (++ticks === 2) { clearInterval(interval); print('INTERVAL_OK'); } }, 1);
""", 0, ('TIMER_OK', 'INTERVAL_OK', 'REALM_TIMER_OK')),
        ('timer-throw', "setTimeout(() => { throw Error('TIMER_FAILURE'); }, 1);", 1, 'TIMER_FAILURE'),
        ('job-throw', job_failure, 1, 'JOB_FAILURE'),
        ('timer-job-throw', 'setTimeout(() => {' + job_failure + '}, 1);', 1, 'JOB_FAILURE'),
        ('realm-job-throw', 'runString(' + repr(job_failure) + ');', 1, 'JOB_FAILURE'),
        ('invalid-interval', """
let thrown = false;
try { var id = setInterval(42, 1); }
catch (e) { thrown = e instanceof TypeError; }
if (typeof id !== 'undefined') clearInterval(id);
if (!thrown) throw Error('INTERVAL_NOT_REJECTED');
print('INTERVAL_INPUT_OK');
""", 0, 'INTERVAL_INPUT_OK'),
        ('missing-file', "load('does-not-exist');", 1, 'cannot read'),
        ('throw', "throw Error('SYNC_FAILURE');", 1, 'SYNC_FAILURE'),
        ('reject', "Promise.reject(Error('ASYNC_FAILURE'));", 1, 'ASYNC_FAILURE'),
        ('realm-throw', "runString('throw Error(\"REALM_FAILURE\")');", 1, 'REALM_FAILURE'),
    ]
    for name, source, code, marker in cases:
        (root/'main.js').write_text(source)
        result = subprocess.run([binary, 'main.js', 'argument'], cwd=root, capture_output=True, text=True, timeout=20)
        markers = (marker,) if isinstance(marker, str) else marker
        assert result.returncode == code and all(m in result.stdout + result.stderr for m in markers), (name, result.returncode, result.stdout, result.stderr)
        print(name + ': PASS')
