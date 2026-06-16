#!/usr/bin/env node
'use strict';

// OOM no-panic architecture rule.
//
// Once OOM is a catchable JS error (eecf6c8: OutOfMemory -> InternalError
// mapping, preallocated OOM error object, zero-allocation tryCatchInFrame
// delivery), any code path that turns an allocation failure into a process
// abort silently breaks that contract. This check pins the strictest
// enforceable tier with static line rules over non-test engine sources
// (src/** excluding src/tests/**):
//
//   rule A  every `@panic(` requires an allowlist entry (catches OOM aborts
//           regardless of message wording, and keeps the general panic
//           surface explicit);
//   rule B  discarding `error.OutOfMemory` into `unreachable` / `@panic`
//           (switch prongs or any line pairing OutOfMemory with them) is
//           flagged - allowlist-able but expected to stay at zero;
//   rule C  `catch unreachable` / `catch @panic` on a line that contains an
//           allocation marker (memory./allocator./alloc(/create(/dupe(/
//           append(/toOwnedSlice/realloc/OutOfMemory) requires an entry.
//
// Chosen strength and current exemptions (2026-06): the allowlist is capped
// at 10 entries and currently holds exactly 1 - the rope-flatten last
// resort in src/core/string.zig (borrowed-slice readers cannot propagate
// errors; it retries after one object-cycle collection before aborting).
// All other historical OOM panics were retired by eecf6c8.
//
// Allowlist shape mirrors deps-allowlist.json: each entry carries
// source/pattern/reason/exit_milestone, duplicates are rejected, each entry
// covers exactly ONE occurrence of `pattern` in `source` (a second
// occurrence in the same file is a violation), and entries that no longer
// match anything fail the check as stale.

const fs = require('fs');
const path = require('path');

const repoRoot = process.cwd();
const allowlistPath = path.join(repoRoot, 'tools/architecture/oom-panics-allowlist.json');
const max_allowlist_entries = 10;

function toPosix(filePath) {
  return filePath.split(path.sep).join('/');
}

function normalizeRepoPath(filePath) {
  return toPosix(path.normalize(filePath)).replace(/^\.\//, '');
}

function fail(message) {
  console.error(`architecture OOM-panic check failed: ${message}`);
  process.exit(1);
}

const known_patterns = new Set(['@panic', 'oom-discard', 'catch-unreachable-alloc']);

function readAllowlist() {
  const raw = fs.readFileSync(allowlistPath, 'utf8');
  const entries = JSON.parse(raw);
  if (!Array.isArray(entries)) fail(`allowlist must be a JSON array: ${allowlistPath}`);
  if (entries.length > max_allowlist_entries) {
    fail(`allowlist has ${entries.length} entries; the strict tier caps it at ${max_allowlist_entries}`);
  }
  const seen = new Set();
  for (const [index, entry] of entries.entries()) {
    for (const field of ['source', 'pattern', 'reason', 'exit_milestone']) {
      if (typeof entry[field] !== 'string' || entry[field].length === 0) {
        fail(`allowlist entry ${index} is missing non-empty ${field}`);
      }
    }
    if (!known_patterns.has(entry.pattern)) {
      fail(`allowlist entry ${index} has unknown pattern "${entry.pattern}" (expected one of: ${[...known_patterns].join(', ')})`);
    }
    entry.source = normalizeRepoPath(entry.source);
    const key = allowKey(entry.source, entry.pattern);
    if (seen.has(key)) fail(`duplicate allowlist entry for ${key} (each entry covers exactly one occurrence)`);
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

function allowKey(source, pattern) {
  return `${source} :: ${pattern}`;
}

const alloc_marker_re = /memory\.|allocator\.|\balloc\(|\bcreate\(|\bdupe\(|\bappend\(|toOwnedSlice|realloc|OutOfMemory/;

function findingsFor(source) {
  const text = fs.readFileSync(path.join(repoRoot, source), 'utf8');
  const findings = [];
  const lines = text.split('\n');
  for (const [lineIndex, rawLine] of lines.entries()) {
    // Strip line comments so commented-out code does not trip the rules.
    const commentStart = rawLine.indexOf('//');
    const line = commentStart === -1 ? rawLine : rawLine.slice(0, commentStart);
    const lineno = lineIndex + 1;
    if (line.includes('@panic(')) {
      findings.push({ source, lineno, pattern: '@panic', rule: 'A: @panic in engine sources requires an allowlist entry', text: rawLine.trim() });
    }
    if (/error\.OutOfMemory\s*=>\s*(unreachable|@panic)/.test(line) ||
        (line.includes('OutOfMemory') && /(\bunreachable\b|@panic\()/.test(line) && !line.includes('@panic('))) {
      findings.push({ source, lineno, pattern: 'oom-discard', rule: 'B: error.OutOfMemory must propagate, not become unreachable/@panic', text: rawLine.trim() });
    }
    if (/catch\s+(unreachable|@panic)/.test(line) && alloc_marker_re.test(line)) {
      findings.push({ source, lineno, pattern: 'catch-unreachable-alloc', rule: 'C: allocation results must not be discarded with catch unreachable/@panic', text: rawLine.trim() });
    }
  }
  return findings;
}

const allowlist = readAllowlist();
const allowBudget = new Map();
for (const entry of allowlist) {
  allowBudget.set(allowKey(entry.source, entry.pattern), { entry, budget: 1, used: 0 });
}

const files = [];
walk(path.join(repoRoot, 'src'), files);

const violations = [];
let finding_count = 0;
for (const source of files) {
  if (source.startsWith('src/tests/')) continue;
  for (const finding of findingsFor(source)) {
    finding_count += 1;
    const key = allowKey(finding.source, finding.pattern);
    const allow = allowBudget.get(key);
    if (allow && allow.used < allow.budget) {
      allow.used += 1;
      continue;
    }
    violations.push(finding);
  }
}

const stale = allowlist.filter((entry) => {
  const allow = allowBudget.get(allowKey(entry.source, entry.pattern));
  return !allow || allow.used === 0;
});

if (violations.length !== 0 || stale.length !== 0) {
  if (violations.length !== 0) {
    console.error('\nOOM-panic rule violations:');
    for (const violation of violations) {
      console.error(`  ${violation.source}:${violation.lineno}: ${violation.text}`);
      console.error(`    rule ${violation.rule}`);
    }
  }
  if (stale.length !== 0) {
    console.error('\nStale OOM-panic allowlist entries (no matching occurrence):');
    for (const entry of stale) {
      console.error(`  ${allowKey(entry.source, entry.pattern)}`);
      console.error(`    exit_milestone: ${entry.exit_milestone}`);
    }
  }
  process.exit(1);
}

console.log(`architecture OOM-panic check ok (${files.length} Zig files scanned, ${finding_count} matched occurrence(s), ${allowlist.length}/${max_allowlist_entries} allowlist entries)`);
