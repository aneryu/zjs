#!/usr/bin/env node
'use strict';

// LEGACY PIPELINE ERADICATION GATE.
//
// `13b9a655` deleted the legacy compiler's production ENTRY and its migration
// machinery, and the dossier read as if the legacy compiler were gone. It was
// not: `pipeline_resolve_variables` and `pipeline_resolve_labels` were still in
// the tree, still `pub`, and `nm` found 70 of their symbols LINKED INTO THE
// SHIPPING ReleaseFast BINARY, because the backend was selected at run time on
// `def.v2_builder != null` and the fd-less pass entries were reachable from the
// test suite.
//
// "The entry is unreachable" is a weaker claim than "the code is gone", and it
// is the weaker claim that was true. This gate asserts the stronger one, twice
// and by different means:
//
//   1. SOURCE. No file reachable from a production root may name a retired
//      token. Reachability is computed the same way check_deps.js computes it,
//      so a file that is only reachable from a test root is not production and
//      is not scanned. Comments are stripped first: these rules are about code,
//      and the prose that explains why a thing was deleted must be allowed to
//      name it.
//
//   2. BINARY. `nm` over the shipped ReleaseFast artifact must find EXACTLY
//      ZERO symbols for the retired namespaces. This is the check that would
//      have failed at 13b9a655, and it is deliberately independent of the
//      source scan: it cannot be satisfied by renaming a reference, only by the
//      code genuinely not being linked.
//
//   3. PHASE BOUNDARIES. The two explicit `noinline` declarations that make
//      legacy deletion performance-stable must remain declarations in source
//      and independent symbols in the ReleaseFast binary. Functional tests do
//      not detect LLVM folding these stages back into the packed finalizer.
//
// Usage: check_legacy_pipelines_gone.js <path-to-zjs-binary>

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const repoRoot = process.cwd();

// The namespaces themselves, plus the two names that made the legacy backend a
// RUN-TIME choice: `runPhases` drove the two legacy passes and `lowerLegacyPhase1`
// was the `else` arm of the backend dispatch in `createFunctionBytecodeAfterChildren`.
const RETIRED_SOURCE_TOKENS = [
  'pipeline_resolve_variables',
  'pipeline_resolve_labels',
  'lowerLegacyPhase1',
  'runPhases',
];

// Symbol-name fragments. Zig mangles these as `bytecode.pipeline_resolve_*.<fn>`.
const RETIRED_SYMBOL_TOKENS = [
  'pipeline_resolve_variables',
  'pipeline_resolve_labels',
];

const REQUIRED_PHASE_BOUNDARIES = [
  {
    file: 'src/compiler_v2/root.zig',
    declaration: 'pub noinline fn compileFunctionV2ForPackedFinalize',
    symbol: 'compileFunctionV2ForPackedFinalize',
  },
  {
    file: 'src/bytecode.zig',
    declaration: 'noinline fn computeStackSizeForCurrentBytecode',
    symbol: 'computeStackSizeForCurrentBytecode',
  },
];

const PRODUCTION_ROOTS = [
  'src/root.zig',
  'src/internal_root.zig',
  'src/cli/zjs.zig',
  'src/cli/run_test262.zig',
];

function fail(message) {
  console.error(`legacy-pipeline eradication check failed: ${message}`);
  process.exit(1);
}

function toPosix(p) {
  return p.split(path.sep).join('/');
}

function normalizeRepoPath(p) {
  return toPosix(path.normalize(p)).replace(/^\.\//, '');
}

function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    if (fs.statSync(full).isDirectory()) walk(full, out);
    else if (name.endsWith('.zig')) out.push(normalizeRepoPath(path.relative(repoRoot, full)));
  }
}

function importsFor(source) {
  const text = fs.readFileSync(path.join(repoRoot, source), 'utf8');
  const out = [];
  const re = /@import\("([^"]+)"\)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const spec = m[1];
    if (!spec.endsWith('.zig') && !spec.startsWith('./') && !spec.startsWith('../')) continue;
    const resolved = normalizeRepoPath(path.join(path.dirname(source), spec));
    if (resolved.startsWith('src/')) out.push(resolved);
  }
  return out;
}

// Zig has line comments only, so stripping them is exact.
function stripComments(text) {
  return text
    .split('\n')
    .map((line) => {
      let inString = false;
      for (let i = 0; i < line.length; i += 1) {
        const c = line[i];
        if (inString) {
          if (c === '\\') i += 1;
          else if (c === '"') inString = false;
        } else if (c === '"') {
          inString = true;
        } else if (c === '/' && line[i + 1] === '/') {
          return line.slice(0, i);
        }
      }
      return line;
    })
    .join('\n');
}

const files = [];
walk(path.join(repoRoot, 'src'), files);

const edges = new Map(files.map((f) => [f, importsFor(f)]));
for (const root of PRODUCTION_ROOTS) {
  if (!edges.has(root)) fail(`production root does not exist: ${root}`);
}
const productionReachable = new Set(PRODUCTION_ROOTS);
const queue = [...PRODUCTION_ROOTS];
while (queue.length) {
  for (const target of edges.get(queue.pop()) || []) {
    if (!productionReachable.has(target)) {
      productionReachable.add(target);
      queue.push(target);
    }
  }
}

// ---- 1. source ------------------------------------------------------------
const sourceHits = [];
for (const file of [...productionReachable].sort()) {
  const code = stripComments(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
  const lines = code.split('\n');
  for (const token of RETIRED_SOURCE_TOKENS) {
    const re = new RegExp(`\\b${token}\\b`);
    lines.forEach((line, idx) => {
      if (re.test(line)) sourceHits.push(`${file}:${idx + 1}: ${token}  |${line.trim()}`);
    });
  }
}
if (sourceHits.length !== 0) {
  console.error('\nRetired legacy-pipeline tokens are referenced from production source:');
  for (const hit of sourceHits) console.error(`  ${hit}`);
  console.error('\n  These names were deleted in COMMIT-B2. Re-introducing one -- even as a');
  console.error('  facade kept alive for a test -- rebuilds exactly the surface that was removed.');
  console.error('  A test that needs the legacy behaviour must be migrated to a V2 fixture.');
  process.exit(1);
}

for (const boundary of REQUIRED_PHASE_BOUNDARIES) {
  const code = stripComments(fs.readFileSync(path.join(repoRoot, boundary.file), 'utf8'));
  if (!code.includes(boundary.declaration)) {
    fail(`${boundary.file} must retain \`${boundary.declaration}\`; this is the ` +
         'measured compiler-stage boundary that made legacy deletion performance-stable');
  }
}

// ---- 2. binary ------------------------------------------------------------
const binary = process.argv[2];
if (!binary) fail('no binary path given (expected the ReleaseFast zjs artifact)');
if (!fs.existsSync(binary)) {
  fail(`binary not found: ${binary} (build it first: zig build zjs)`);
}

let nmOut;
try {
  nmOut = execFileSync('nm', [binary], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
} catch (err) {
  // A gate that cannot read the artifact must say so, not pass by default.
  fail(`nm failed on ${binary}: ${err.message}`);
}

const symbolLines = nmOut.split('\n');
const symbolHits = symbolLines.filter((line) =>
  RETIRED_SYMBOL_TOKENS.some((token) => line.includes(token)));

if (symbolHits.length !== 0) {
  console.error(`\n${symbolHits.length} retired legacy-pipeline symbol(s) are linked into ${binary}:`);
  for (const hit of symbolHits.slice(0, 40)) console.error(`  ${hit.trim()}`);
  if (symbolHits.length > 40) console.error(`  ... and ${symbolHits.length - 40} more`);
  console.error('\n  The requirement is that the shipped binary genuinely LACKS this code, not');
  console.error('  that some entry into it is unreachable. 70 of these symbols shipped at');
  console.error('  13b9a655 while the dossier described the legacy compiler as deleted.');
  process.exit(1);
}


for (const boundary of REQUIRED_PHASE_BOUNDARIES) {
  if (!symbolLines.some((line) => line.includes(boundary.symbol))) {
    fail(`ReleaseFast binary has no independent \`${boundary.symbol}\` symbol; ` +
         'Zig/LLVM may have folded a required compiler stage back into the packed finalizer');
  }
}

// A gate whose subject vanished silently is worthless: prove nm read the file
// and that the retained rule surface IS present under its own name.
const totalSymbols = symbolLines.filter((line) => line.trim().length !== 0).length;
if (totalSymbols === 0) fail(`nm produced no symbols for ${binary}; the check would be vacuous`);
const bindingRuleSymbols = symbolLines.filter((line) => line.includes('binding_rules')).length;
if (bindingRuleSymbols === 0) {
  fail('no `binding_rules` symbols in the binary; the retained QuickJS binding-rule surface ' +
       'should still be linked, so the zero above may be measuring the wrong artifact');
}

console.log(
  `legacy-pipeline eradication ok (${productionReachable.size} production-reachable files clean; ` +
  `0 of ${totalSymbols} symbols in ${path.basename(binary)} are pipeline_resolve_*; ` +
  `${bindingRuleSymbols} binding_rules symbols and ` +
  `${REQUIRED_PHASE_BOUNDARIES.length} compiler-stage boundaries retained)`,
);
