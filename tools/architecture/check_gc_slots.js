#!/usr/bin/env node
'use strict';

// Naked heap-GC-reference lint (tracing-gc-design.md §5.2).
//
// Heap structs under src/core and src/bytecode.zig that store JSValue,
// *Object, *Shape, *VarRef, *FunctionBytecode, RealmRef, or slices/pointers
// of those types must be one of:
//
//   - tagged `// gc-slot: heap` (writes go through Slot / named bulk API)
//   - tagged `// gc-slot: immutable` (sealed after publish)
//   - tagged `// gc-slot: weak` (identity, reverse link, membership)
//   - listed in gc-slots-allowlist.json (shrinking; baseline is recorded)
//
// New untagged fields fail. Allowlist entries that no longer match fail as
// stale. The allowlist must not grow without an explicit baseline bump in
// this file's `baseline_count`.

const fs = require('fs');
const path = require('path');

const repoRoot = process.cwd();
const allowlistPath = path.join(repoRoot, 'tools/architecture/gc-slots-allowlist.json');
const dump = process.argv.includes('--dump');

const gcTypeRe =
  /^(?:\?)?(?:\*)?(?:\[\]|\[[*]\])?(?:\?\*)?(?:[A-Za-z_][A-Za-z0-9_]*\.)?(?:JSValue|Object|Shape|VarRef|FunctionBytecode|RealmRef|JSContext|ModuleRecord|String(?:Rope)?|BigInt|Entry)\b/;

const skipTypeRe = /^(?:\?\[\*\])?u8\b|FILE\b|anyopaque\b|Atom\b|usize\b/;

function toPosix(filePath) {
  return filePath.split(path.sep).join('/');
}

function normalizeRepoPath(filePath) {
  return toPosix(path.normalize(filePath)).replace(/^\.\//, '');
}

function fail(message) {
  console.error(`architecture gc-slot check failed: ${message}`);
  process.exit(1);
}

function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) {
      if (name === 'tests') continue;
      walk(full, out);
    } else if (name.endsWith('.zig')) {
      out.push(normalizeRepoPath(path.relative(repoRoot, full)));
    }
  }
}

function stripLineComment(line) {
  const idx = line.indexOf('//');
  if (idx === -1) return { code: line, comment: '' };
  return { code: line.slice(0, idx), comment: line.slice(idx) };
}

function slotTag(comment, prevComment) {
  const text = `${prevComment} ${comment}`;
  if (/\bgc-slot:\s*heap\b/.test(text)) return 'heap';
  if (/\bgc-slot:\s*immutable\b/.test(text)) return 'immutable';
  if (/\bgc-slot:\s*weak\b/.test(text)) return 'weak';
  return null;
}

function isGcFieldType(typeText) {
  const t = typeText.replace(/\s+/g, '');
  if (skipTypeRe.test(t)) return false;
  if (t.includes('Payload') && !t.includes('JSValue')) return false;
  return gcTypeRe.test(t);
}

function skipStructName(name) {
  return (
    name.endsWith('Options') ||
    name.endsWith('Error') ||
    name.endsWith('Lookup') ||
    name.endsWith('Visit') ||
    name.endsWith('Callback') ||
    name.endsWith('Host') ||
    name === 'binding_rules'
  );
}

function scanFile(relPath) {
  const text = fs.readFileSync(path.join(repoRoot, relPath), 'utf8');
  const lines = text.split('\n');
  const findings = [];
  const structStack = [];
  let depth = 0;
  let fnSkip = null; // 'await' | number (body depth)
  let prevComment = '';

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const { code, comment } = stripLineComment(raw);
    const trimmed = code.trim();
    if (trimmed.length === 0) {
      if (comment) prevComment = comment;
      continue;
    }

    const startsFn =
      /^(?:pub\s+)?(?:export\s+)?(?:noinline\s+)?(?:inline\s+)?fn\s+/.test(trimmed) ||
      /^test\s+"/.test(trimmed) ||
      /^comptime\s*\{/.test(trimmed);
    if (fnSkip === null && startsFn) fnSkip = 'await';

    const structMatch = trimmed.match(
      /^(?:pub\s+)?(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:extern\s+)?struct\s*\{/,
    );
    if (structMatch && fnSkip === null) {
      structStack.push({ name: structMatch[1], depth, skip: skipStructName(structMatch[1]) });
    }

    const opens = (code.match(/\{/g) || []).length;
    const closes = (code.match(/\}/g) || []).length;

    if (fnSkip === null) {
      const fieldMatch = trimmed.match(
        /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^=,]+?)(?:\s*=.*)?(?:,)?$/,
      );
      const current = structStack[structStack.length - 1];
      if (
        fieldMatch &&
        current &&
        !current.skip &&
        !trimmed.startsWith('fn ')
      ) {
        const typeText = fieldMatch[2].replace(/,$/, '').trim();
        if (isGcFieldType(typeText)) {
          const tag = slotTag(comment, prevComment);
          findings.push({
            file: relPath,
            struct: current.name,
            field: fieldMatch[1],
            type: typeText,
            line: i + 1,
            tag,
          });
        }
      }
    }

    const before = depth;
    depth += opens - closes;
    if (fnSkip === 'await' && opens > 0) fnSkip = before + 1;
    else if (typeof fnSkip === 'number' && depth < fnSkip) fnSkip = null;
    while (structStack.length && structStack[structStack.length - 1].depth >= depth) {
      structStack.pop();
    }
    prevComment = comment;
  }
  return findings;
}

function allowKey(entry) {
  return `${entry.file}::${entry.struct}::${entry.field}`;
}

function readAllowlist() {
  const raw = JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
  if (typeof raw.baseline_count !== 'number') fail('allowlist missing baseline_count');
  if (!Array.isArray(raw.entries)) fail('allowlist missing entries array');
  const seen = new Set();
  for (const [index, entry] of raw.entries.entries()) {
    for (const field of ['file', 'struct', 'field', 'kind', 'reason']) {
      if (typeof entry[field] !== 'string' || entry[field].length === 0) {
        fail(`allowlist entry ${index} is missing non-empty ${field}`);
      }
    }
    entry.file = normalizeRepoPath(entry.file);
    const key = allowKey(entry);
    if (seen.has(key)) fail(`duplicate allowlist entry for ${key}`);
    seen.add(key);
  }
  if (raw.entries.length > raw.baseline_count) {
    fail(
      `allowlist grew from baseline ${raw.baseline_count} to ${raw.entries.length}; the list is shrinking-only`,
    );
  }
  return raw;
}

const files = [];
walk(path.join(repoRoot, 'src/core'), files);
if (fs.existsSync(path.join(repoRoot, 'src/bytecode.zig'))) files.push('src/bytecode.zig');
const bytecodeDir = path.join(repoRoot, 'src/bytecode');
if (fs.existsSync(bytecodeDir)) walk(bytecodeDir, files);

const findings = [];
for (const file of files) {
  if (file.endsWith('/gc_slot.zig') || file.endsWith('/gc_write_audit.zig')) continue;
  findings.push(...scanFile(file));
}

if (dump) {
  const entries = findings
    .filter((f) => !f.tag)
    .map((f) => ({
      file: f.file,
      struct: f.struct,
      field: f.field,
      type: f.type,
      kind: 'mutable',
      reason: `line ${f.line}`,
    }));
  process.stdout.write(
    JSON.stringify({ baseline_count: entries.length, entries }, null, 2) + '\n',
  );
  process.exit(0);
}

const allowlist = readAllowlist();
const allowKeys = new Set(allowlist.entries.map(allowKey));
const foundKeys = new Set();
const naked = [];

for (const finding of findings) {
  const key = allowKey(finding);
  if (finding.tag) {
    if (allowKeys.has(key)) {
      fail(`${key} is tagged gc-slot:${finding.tag} but still on the allowlist; remove it to shrink`);
    }
    continue;
  }
  foundKeys.add(key);
  if (!allowKeys.has(key)) naked.push(finding);
}

const stale = allowlist.entries.filter((entry) => !foundKeys.has(allowKey(entry)));
if (naked.length !== 0) {
  const shown = naked
    .slice(0, 20)
    .map((f) => `  ${f.file}:${f.line} ${f.struct}.${f.field}: ${f.type}`)
    .join('\n');
  fail(
    `${naked.length} untagged naked GC field(s); tag gc-slot:heap/immutable/weak or add to the allowlist (shrinking-only):\n${shown}`,
  );
}
if (stale.length !== 0) {
  fail(
    `${stale.length} stale allowlist entries:\n${stale.map((e) => `  ${allowKey(e)}`).join('\n')}`,
  );
}

process.stdout.write(
  `architecture gc-slot check passed: ${foundKeys.size} allowlisted, ` +
    `${findings.length - foundKeys.size} tagged, baseline ${allowlist.baseline_count}\n`,
);
