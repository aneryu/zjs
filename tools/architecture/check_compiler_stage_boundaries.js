#!/usr/bin/env node
'use strict';

// Compiler-stage boundary gate.
//
// QCP-1B deletion was performance-stable only after V2 lowering and the
// stack-size walk were kept as explicit non-inlined stages. Functional tests
// do not detect LLVM folding those stages back into the packed finalizer.
//
// Usage:
//   check_compiler_stage_boundaries.js --source-only
//   check_compiler_stage_boundaries.js <path-to-zjs-binary>
//
// `--source-only` is the checkpoint half: the `noinline` declarations remain
// in source. The ReleaseFast `nm` half stays on the production gate, which
// already compiles that artifact.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const repoRoot = process.cwd();

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

function fail(message) {
  console.error(`compiler-stage boundary check failed: ${message}`);
  process.exit(1);
}

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

for (const boundary of REQUIRED_PHASE_BOUNDARIES) {
  const sourcePath = path.join(repoRoot, boundary.file);
  if (!fs.existsSync(sourcePath)) fail(`missing ${boundary.file}`);
  const code = stripComments(fs.readFileSync(sourcePath, 'utf8'));
  if (!code.includes(boundary.declaration)) {
    fail(`${boundary.file} must retain \`${boundary.declaration}\`; this is the ` +
         'measured compiler-stage boundary that made legacy deletion performance-stable');
  }
}

const arg = process.argv[2];
if (arg === '--source-only') {
  console.log(
    `compiler-stage boundary source check ok (${REQUIRED_PHASE_BOUNDARIES.length} noinline declarations retained)`,
  );
  process.exit(0);
}

const binary = arg;
if (!binary) fail('expected --source-only or the ReleaseFast zjs artifact path');
if (!fs.existsSync(binary)) {
  fail(`binary not found: ${binary} (build it first: zig build zjs)`);
}

let nmOut;
try {
  nmOut = execFileSync('nm', [binary], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
} catch (err) {
  fail(`nm failed on ${binary}: ${err.message}`);
}

const symbolLines = nmOut.split('\n');
const totalSymbols = symbolLines.filter((line) => line.trim().length !== 0).length;
if (totalSymbols === 0) fail(`nm produced no symbols for ${binary}; the check would be vacuous`);

for (const boundary of REQUIRED_PHASE_BOUNDARIES) {
  if (!symbolLines.some((line) => line.includes(boundary.symbol))) {
    fail(`ReleaseFast binary has no independent \`${boundary.symbol}\` symbol; ` +
         'Zig/LLVM may have folded a required compiler stage back into the packed finalizer');
  }
}

console.log(
  `compiler-stage boundary check ok (${REQUIRED_PHASE_BOUNDARIES.length} independent symbols in ${path.basename(binary)})`,
);
