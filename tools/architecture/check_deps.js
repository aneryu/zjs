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
    if (target === 'src/kernel/root.zig' || target === 'src/runtime/public.zig') return null;
    return 'public root may only import kernel/root.zig and runtime/public.zig';
  }

  if (source.startsWith('src/core/')) {
    const disallowed = [
      'src/bytecode/',
      'src/builtins/',
      'src/cli/',
      'src/exec/',
      'src/frontend/',
      'src/runtime/',
      'src/tools/',
    ];
    return targetStarts(target, disallowed) ? 'core must not depend on bytecode, builtins, exec, frontend, runtime, CLI, or tools' : null;
  }

  if (source.startsWith('src/kernel/')) {
    const disallowed = [
      'src/bytecode/',
      'src/builtins/',
      'src/cli/',
      'src/exec/',
      'src/frontend/',
      'src/libs/',
      'src/runtime/',
      'src/tools/',
    ];
    return targetStarts(target, disallowed) ? 'kernel may import core/kernel only; it must not depend on exec, runtime, frontend, bytecode, builtins, libs, CLI, or tools' : null;
  }

  if (source.startsWith('src/builtins/')) {
    const disallowed = [
      'src/bytecode/',
      'src/cli/',
      'src/exec/',
      'src/frontend/',
      'src/runtime/',
      'src/tools/',
    ];
    return targetStarts(target, disallowed) ? 'builtins may import core/libs/builtins only; exec/runtime/frontend/bytecode/CLI/tools dependencies must be explicit debt' : null;
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

console.log(`architecture dependency check ok (${files.length} Zig files, ${matchedAllowKeys.size} transitional allowlist entries)`);
