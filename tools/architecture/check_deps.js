#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repoRoot = process.cwd();
const allowlistPath = path.join(repoRoot, 'tools/architecture/deps-allowlist.json');

function toPosix(filePath) {
  return filePath.split(path.sep).join('/');
}

function normalizeRepoPath(filePath) {
  return toPosix(path.normalize(filePath)).replace(/^\.\//, '');
}

function readAllowlist() {
  const raw = fs.readFileSync(allowlistPath, 'utf8');
  const entries = JSON.parse(raw);
  if (!Array.isArray(entries)) fail(`allowlist must be a JSON array: ${allowlistPath}`);
  const seen = new Set();
  for (const [index, entry] of entries.entries()) {
    for (const field of ['source', 'import', 'reason', 'exit_milestone']) {
      if (typeof entry[field] !== 'string' || entry[field].length === 0) {
        fail(`allowlist entry ${index} is missing non-empty ${field}`);
      }
    }
    entry.source = normalizeRepoPath(entry.source);
    entry.import = normalizeRepoPath(entry.import);
    const key = allowKey(entry.source, entry.import);
    if (seen.has(key)) fail(`duplicate allowlist entry for ${key}`);
    seen.add(key);
  }
  return entries;
}

function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) {
      walk(full, out);
    } else if (name.endsWith('.zig')) {
      out.push(normalizeRepoPath(path.relative(repoRoot, full)));
    }
  }
}

function resolveImport(source, specifier) {
  if (
    !specifier.endsWith('.zig') &&
    !specifier.startsWith('./') &&
    !specifier.startsWith('../')
  ) {
    return null;
  }
  const resolved = normalizeRepoPath(path.join(path.dirname(source), specifier));
  if (!resolved.startsWith('src/')) return null;
  return resolved;
}

function importsFor(source) {
  const text = fs.readFileSync(path.join(repoRoot, source), 'utf8');
  const imports = [];
  const importRe = /@import\("([^"]+)"\)/g;
  let match;
  while ((match = importRe.exec(text)) !== null) {
    const target = resolveImport(source, match[1]);
    if (target) imports.push({ source, target, specifier: match[1] });
  }
  return imports;
}

function allowKey(source, target) {
  return `${source} -> ${target}`;
}

function targetStarts(target, prefixes) {
  return prefixes.some((prefix) => target === prefix || target.startsWith(prefix));
}

function violationReason(source, target) {
  if (source === 'src/internal_root.zig' || source === 'src/all_tests.zig') return null;

  if (source === 'src/root.zig') {
    if (
      target === 'src/binding/root.zig' ||
      target === 'src/runtime/public.zig' ||
      target === 'src/core/root.zig' ||
      target === 'src/exec/root.zig' ||
      target === 'src/exec/module_graph.zig'
    ) return null;
    return 'public root may only import modules used by the embedding facade adapter';
  }

  if (source.startsWith('src/core/')) {
    const disallowed = [
      'src/builtins/',
      'src/cli/',
      'src/exec/',
      'src/parser.zig',
      'src/runtime/',
    ];
    return targetStarts(target, disallowed) ? 'core must not depend on parser, builtins, exec, runtime, or CLI' : null;
  }

  if (source.startsWith('src/libs/')) {
    const disallowed = [
      'src/binding/',
      'src/builtins/',
      'src/bytecode.zig',
      'src/cli/',
      'src/exec/',
      'src/parser.zig',
      'src/runtime/',
    ];
    return targetStarts(target, disallowed) ? 'libs may import core/libs only' : null;
  }

  if (source === 'src/parser.zig') {
    const disallowed = [
      'src/binding/',
      'src/builtins/',
      'src/cli/',
      'src/exec/',
      'src/runtime/',
    ];
    return targetStarts(target, disallowed) ? 'parser may import core/libs/bytecode only (the parser emits bytecode directly); builtins/exec/runtime/binding/CLI dependencies must be explicit debt' : null;
  }

  if (source === 'src/bytecode.zig') {
    const disallowed = [
      'src/binding/',
      'src/builtins/',
      'src/cli/',
      'src/exec/',
      'src/parser.zig',
      'src/runtime/',
    ];
    return targetStarts(target, disallowed) ? 'bytecode may import core/libs only' : null;
  }

  if (source.startsWith('src/exec/')) {
    const disallowed = [
      'src/binding/',
      'src/builtins/',
      'src/cli/',
      'src/runtime/',
    ];
    return targetStarts(target, disallowed) ? 'exec must not depend on the retired builtins directory, runtime, binding, or CLI; standard-global bootstrap and native operation modules are owned by exec. Host policy reaches exec through core interfaces (e.g. HostEventLoop) or the external host-function registry' : null;
  }

  if (source.startsWith('src/runtime/')) {
    const disallowed = ['src/cli/'];
    return targetStarts(target, disallowed) ? 'runtime must not depend on CLI' : null;
  }

  if (source.startsWith('src/binding/')) {
    const disallowed = ['src/cli/'];
    return targetStarts(target, disallowed) ? 'binding must not depend on CLI' : null;
  }

  if (source.startsWith('src/compiler/')) {
    // Observed production import face: core, bytecode, parser, plus
    // intra-package files. compiler/tests.zig is the in-tree oracle and
    // additionally imports exec to run compiled bytecode; it still may not
    // reach cli/runtime/binding.
    const disallowed = source === 'src/compiler/tests.zig'
      ? ['src/cli/', 'src/runtime/', 'src/binding/']
      : ['src/cli/', 'src/runtime/', 'src/exec/', 'src/binding/'];
    return targetStarts(target, disallowed)
      ? 'compiler production files may import core/bytecode/parser/libs only; cli/runtime/exec/binding are forbidden (tests.zig may import exec)'
      : null;
  }

  return null;
}

function fail(message) {
  console.error(`architecture dependency check failed: ${message}`);
  process.exit(1);
}

const allowlist = readAllowlist();
const allowByKey = new Map(allowlist.map((entry) => [allowKey(entry.source, entry.import), entry]));
const matchedAllowKeys = new Set();

const files = [];
walk(path.join(repoRoot, 'src'), files);
for (const extraDir of ['tools', 'tests']) {
  const extra = [];
  walk(path.join(repoRoot, extraDir), extra);
  for (const file of extra) {
    const text = fs.readFileSync(path.join(repoRoot, file), 'utf8');
    if (text.includes('@import("zjs")')) files.push(file);
  }
}

// Production-module reachability. The import-edge rules above validate edges
// that EXIST; they cannot see a module that nothing imports. The 2026-07-31
// opcode-profiling regression survived because vm_profile.zig fell out of
// the production graph silently. Solve reachability from the production and
// test roots separately; a module reachable from neither must carry an
// orphan-allowlist entry with a reason and an exit milestone.
const PRODUCTION_ROOTS = [
  'src/root.zig',
  'src/internal_root.zig',
  'src/cli/zjs.zig',
  'src/cli/run_test262.zig',
];
const TEST_ROOTS = [
  'src/all_tests.zig',
  // Focused-suite and gate roots referenced directly by build.zig.
  'src/exec_tests.zig',
  'src/builtins_tests.zig',
  'src/core_tests.zig',
  'src/parser_tests.zig',
  'src/bytecode_tests.zig',
  'src/runner_tests.zig',
  'src/embedding_tests.zig',
  'src/compiler_tests.zig',
  'src/runtime_tests.zig',
  'src/tests/oom.zig',
  'src/tests/smoke_test.zig',
  // tools/ and tests/ files that import the zjs module (scanned for edges;
  // they are build-graph roots, not orphans).
  'tools/perf/same_runtime/zjs_same_runtime.zig',
  'tools/perf/direct/zjs_direct_bench.zig',
  'tests/fixtures/runtime_plugin_fixture.zig',
  'tests/fixtures/runtime_empty_plugin_fixture.zig',
];
const orphanAllowlistPath = path.join(repoRoot, 'tools/architecture/orphan-allowlist.json');

function readOrphanAllowlist() {
  const entries = JSON.parse(fs.readFileSync(orphanAllowlistPath, 'utf8'));
  if (!Array.isArray(entries)) fail(`orphan allowlist must be a JSON array: ${orphanAllowlistPath}`);
  for (const [index, entry] of entries.entries()) {
    for (const field of ['module', 'reason', 'exit_milestone']) {
      if (typeof entry[field] !== 'string' || entry[field].length === 0) {
        fail(`orphan allowlist entry ${index} is missing non-empty ${field}`);
      }
    }
    entry.module = normalizeRepoPath(entry.module);
  }
  return entries;
}

function reachableFrom(roots, edges) {
  const seen = new Set();
  const queue = roots.filter((root) => edges.has(root));
  for (const root of queue) seen.add(root);
  while (queue.length) {
    const source = queue.pop();
    for (const target of edges.get(source) || []) {
      if (!seen.has(target)) {
        seen.add(target);
        queue.push(target);
      }
    }
  }
  return seen;
}

function checkProductionReachability() {
  const edges = new Map();
  for (const source of files) {
    edges.set(source, importsFor(source).map((item) => item.target));
  }
  for (const root of [...PRODUCTION_ROOTS, ...TEST_ROOTS]) {
    if (!edges.has(root)) fail(`reachability root does not exist: ${root}`);
  }
  const productionReachable = reachableFrom(PRODUCTION_ROOTS, edges);
  const testReachable = reachableFrom(TEST_ROOTS, edges);
  const orphans = files.filter((file) => !productionReachable.has(file) && !testReachable.has(file));
  const allowlist = readOrphanAllowlist();
  const allowByModule = new Map(allowlist.map((entry) => [entry.module, entry]));
  const unallowed = orphans.filter((file) => !allowByModule.has(file));
  const staleOrphans = allowlist.filter(
    (entry) => productionReachable.has(entry.module) || testReachable.has(entry.module) || !files.includes(entry.module),
  );
  if (unallowed.length !== 0 || staleOrphans.length !== 0) {
    if (unallowed.length !== 0) {
      console.error('\nModules reachable from neither production nor test roots (orphans):');
      for (const file of unallowed) console.error(`  ${file}`);
      console.error('  Either wire the module back in, delete it, or add an orphan-allowlist entry with a reason and exit milestone.');
    }
    if (staleOrphans.length !== 0) {
      console.error('\nStale orphan-allowlist entries (module is reachable again or gone):');
      for (const entry of staleOrphans) console.error(`  ${entry.module} (exit_milestone: ${entry.exit_milestone})`);
    }
    process.exit(1);
  }
  const testOnly = files.filter((file) => !productionReachable.has(file) && testReachable.has(file));
  return {
    production: productionReachable.size,
    testOnly: testOnly.length,
    allowedOrphans: orphans.length,
  };
}

const retiredBuiltinFiles = files.filter((source) => source.startsWith('src/builtins/'));
if (retiredBuiltinFiles.length !== 0) {
  fail(`legacy src/builtins directory was retired; move these modules to exec or core:\n  ${retiredBuiltinFiles.join('\n  ')}`);
}

const hostFunctionSource = fs.readFileSync(path.join(repoRoot, 'src/core/host_function.zig'), 'utf8');
for (const retiredAbiToken of ['.zjs_internal_call', 'pub const InternalCall =', 'InternalCallFn']) {
  if (hostFunctionSource.includes(retiredAbiToken)) {
    fail(`retired builtin ABI token reintroduced in src/core/host_function.zig: ${retiredAbiToken}`);
  }
}

const standardGlobalsSource = fs.readFileSync(path.join(repoRoot, 'src/exec/standard_globals.zig'), 'utf8');
for (const retiredRegistryToken of ['ConstructorSpec', 'constructor_specs']) {
  if (standardGlobalsSource.includes(retiredRegistryToken)) {
    fail(`generic standard-constructor registry reintroduced in src/exec/standard_globals.zig: ${retiredRegistryToken}`);
  }
}

const propertyIcSource = fs.readFileSync(path.join(repoRoot, 'src/exec/property_ic.zig'), 'utf8');
for (const retiredFacadeToken of ['cachedDataPropertyValueForFastPath']) {
  if (propertyIcSource.includes(retiredFacadeToken)) {
    fail(`proven-dead IC facade reintroduced in src/exec/property_ic.zig: ${retiredFacadeToken} (removed in D2; the inline cache is gone and qjs has none)`);
  }
}

const internalBuiltinsSource = fs.readFileSync(path.join(repoRoot, 'src/exec/internal_builtins.zig'), 'utf8');
for (const completedDomain of ['atomics', 'performance', 'promise']) {
  const tableContribution = `NativeBuiltinDomain.${completedDomain})] = denseRecords`;
  if (!internalBuiltinsSource.includes(tableContribution)) {
    fail(`completed standard-native domain lost its typed record table: ${completedDomain}`);
  }
}

const violations = [];
const actualImportKeys = new Set();

for (const source of files) {
  for (const item of importsFor(source)) {
    const key = allowKey(item.source, item.target);
    actualImportKeys.add(key);
    const reason = violationReason(item.source, item.target);
    if (!reason) continue;
    if (allowByKey.has(key)) {
      matchedAllowKeys.add(key);
      continue;
    }
    violations.push({ ...item, reason });
  }
}

const stale = allowlist.filter((entry) => !actualImportKeys.has(allowKey(entry.source, entry.import)));

if (violations.length !== 0 || stale.length !== 0) {
  if (violations.length !== 0) {
    console.error('\nUnallowed architecture dependencies:');
    for (const violation of violations) {
      console.error(`  ${allowKey(violation.source, violation.target)}`);
      console.error(`    rule: ${violation.reason}`);
    }
  }
  if (stale.length !== 0) {
    console.error('\nStale architecture dependency allowlist entries:');
    for (const entry of stale) {
      console.error(`  ${allowKey(entry.source, entry.import)}`);
      console.error(`    exit_milestone: ${entry.exit_milestone}`);
    }
  }
  process.exit(1);
}

const reachability = checkProductionReachability();
console.log(
  `architecture dependency check ok (${files.length} Zig files, ${matchedAllowKeys.size} transitional allowlist entries, ` +
  `${reachability.production} production-reachable, ${reachability.testOnly} test-only, ${reachability.allowedOrphans} allowlisted orphans)`,
);
