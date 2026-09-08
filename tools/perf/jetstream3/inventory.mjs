import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root = path.resolve(process.argv[2]);
const pin = '06785cf861ac44855f168cbbe829278c2802e6de';
const head = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim();
if (head !== pin) throw Error(`Wrong revision: ${head}`);
if (execFileSync('git', ['-C', root, 'status', '--porcelain', '--untracked-files=no'], {encoding:'utf8'}).trim()) throw Error('Modified upstream');
const context = vm.createContext({console, performance});
vm.runInContext('globalThis.JetStreamParamsSource = new Map([["prefetchResources", "false"]]);', context);
for (const file of ['utils/shell-config.js', 'utils/params.js', 'JetStreamDriver.js']) {
  vm.runInContext(fs.readFileSync(path.join(root,file),'utf8'), context, {filename:file, timeout:10000});
}
const rows = JSON.parse(vm.runInContext(`JSON.stringify(BENCHMARKS.map(function entry(b) {
 return {name:b.name, tags:[...b.tags], kind:b.constructor.name, iterations:b.iterations,
 files:b.files, preloads:b.preloadEntries, children:b.benchmarks?.map(entry)};
}))`,context));
function hash(file) {
 const p = path.resolve(root,file);
 if (!p.startsWith(root + path.sep)) throw Error('External path ' + file);
 return {path:file,bytes:fs.statSync(p).size,sha256:crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')};
}
for (const row of rows) {
 row.scope = !row.tags.includes('default') ? 'upstream-disabled' : !row.tags.includes('js') ? 'non-js' : row.tags.includes('workertests') ? 'worker-host' : 'included';
 // Dependency audit: source-map calls WebAssembly.instantiate in its bundle
 // and preloads mappings.wasm. Other WTB entries share the preload list, so
 // merely having a .wasm preload is not a sufficient exclusion rule.
 if (row.name === 'source-map-wtb' && row.scope === 'included') {
   row.scope = 'wasm-dependency';
   row.exclusionEvidence = 'web-tooling-benchmark/dist/source-map.bundle.js:3452; source-map/lib/mappings.wasm';
 }
 row.execution = row.scope === 'included' ? 'not-run' : 'out-of-scope';
 row.resources = [...new Set([...row.files,...row.preloads.map(x=>x[1])])].map(hash);
}
console.log(JSON.stringify({schemaVersion:2,profile:'js-shell-candidate-v2',upstream:'https://github.com/WebKit/JetStream',branch:'JetStream3.0',commit:head,
 purpose:'inventory only; no benchmark execution or score',selection:'default AND js AND NOT workertests AND NOT audited Wasm dependency; preserve groups',
 driver:hash('JetStreamDriver.js'),counts:Object.fromEntries(['included','upstream-disabled','non-js','worker-host','wasm-dependency'].map(s=>[s,rows.filter(r=>r.scope===s).length])),workloads:rows},null,2));
