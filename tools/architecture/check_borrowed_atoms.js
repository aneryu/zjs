#!/usr/bin/env node
'use strict';

// Borrowed-atom escape rule.
//
// `8c8787cd` made identifier / private-name token atoms actually die
// (qjs `free_token`, quickjs.c:22190). Before it every identifier token
// leaked one retain, so "read an atom out of a token, then advance(), then
// keep using it" was safe by accident. After it that shape is a
// use-after-free -- and `docs/borrowed_atom_audit.md` §4 proved one instance
// (`exportDefaultFunctionName` / `exportDefaultClassName`, fixed in
// `ada949be`) was reachable: the returned atom was already dead at the moment
// of return and only survived because the next intern of the identical string
// popped the same LIFO free slot.
//
// That slot-reuse luck is exactly why no black-box regression test can fail on
// this bug class. The two mechanical replacements are:
//
//   * `-Dzjs_ownership_audit` (build option, one-slot quarantine in
//     `AtomTable.finalizeDeadEntry`) -- breaks the luck at run time so an
//     existing test panics on a real escape;
//   * this checker -- forbids the source shape at review time so the pattern
//     cannot be reintroduced.
//
// See `docs/borrowed_atom_audit.md` §8 for what each does and does not catch.
//
// A *borrowed atom* is an atom id read straight out of a short-lived owner:
//
//   * `<token>.payload.<field>.atom` in value position (an argument position
//     such as `atomNameEquals(s, s.token.payload.ident.atom, "of")` is a read
//     that is consumed inside the token's lifetime, and is not borrowing;
//     `@as` and friends are transparent, so the scan passes through them);
//   * the result of a same-file helper that itself returns a borrowed atom
//     (`identifierLikeAtom`, `classNameAtom`, ...), discovered by fixed point;
//   * a local bound or reassigned to either of the above without taking
//     ownership. Ownership is judged by position, not by "this statement
//     mentions dup", so `return if (c) atoms.dup(a) else t.payload.ident.atom`
//     still reports the else branch, and `nm = atoms.dup(nm)` ends the borrow.
//
// A borrowed atom must not escape its owner's lifetime. Three escapes are
// flagged, reported once per borrowing site under the highest-priority
// pattern:
//
//   rule A  `borrowed-return`            returning it (the `ada949be` bug);
//   rule B  `borrowed-state-store`       storing it into a long-lived
//                                        `State` atom field (the field
//                                        outlives the token);
//   rule C  `borrowed-use-after-release` reading it on a line after an
//                                        un-deferred `advance()` /
//                                        `freeToken()` in the same function.
//
// A fourth rule covers the neighbouring shape the audit filed as B-6:
//
//   rule D  `owned-escape-state-store`   storing a local whose only owner is
//                                        a `defer ...free(local)` into a
//                                        long-lived `State` atom field that
//                                        the same function never restores --
//                                        the field keeps the id after the
//                                        owner dies.
//
// Three ways to be legal, in the order a reader should prefer them:
//
//   1. take ownership in the escaping expression itself -- `.dup(`,
//      `.internString(`, `.newSymbol(`, or a `*Owned(` call;
//   2. name the function `...Owned` (established convention:
//      `moduleImportNameAtomOwned`, `exportDefaultFunctionNameOwned`) -- this
//      exempts rule A only, only for a forwarded borrow (a helper result or a
//      tainted local, which cannot be proved here), only if the function
//      really produces an owner somewhere, and never for a directly returned
//      token payload read: that is the `ada949be` shape itself;
//   3. write `// borrowed-atom: <reason>` on the line directly above the
//      escaping line (rule C also accepts it above the borrowing line, which
//      is where a deliberate long borrow is best explained). The reason must
//      be non-empty; it is the contract the code otherwise fails to state.
//
// Everything else needs an allowlist entry. The allowlist is seeded from the
// audit's class-B sites: correct today, but only because some unrelated third
// party (a `defineVar` dup, an outer dup, a scope var row) happens to hold a
// retain. The ruling calls those follow-ups rather than violations -- they
// must stay visible and must not grow silently, hence the cap.
//
// Allowlist shape mirrors oom-panics-allowlist.json: source / pattern /
// reason / exit_milestone, plus optional `fn` (enclosing function name) and
// `contains` (substring of the flagged statement) selectors to pick out one
// finding when a file has several under the same pattern. Every entry must
// cover exactly ONE finding; entries that no longer match fail as stale.

const fs = require('fs');
const path = require('path');

const repoRoot = process.cwd();
const allowlistPath = path.join(repoRoot, 'tools/architecture/borrowed-atoms-allowlist.json');
const max_allowlist_entries = 16;

const known_patterns = new Set([
  'borrowed-return',
  'borrowed-state-store',
  'borrowed-use-after-release',
  'owned-escape-state-store',
]);

// Highest priority first: a site that escapes several ways is reported once,
// under the escape that is hardest to argue away.
const pattern_priority = [
  'borrowed-return',
  'borrowed-state-store',
  'owned-escape-state-store',
  'borrowed-use-after-release',
];

const rule_text = {
  'borrowed-return': 'A: a borrowed atom must not be returned (dup it, or name the function ...Owned)',
  'borrowed-state-store': 'B: a borrowed atom must not be stored into a long-lived State atom field',
  'borrowed-use-after-release': 'C: a borrowed atom must not be read after advance()/freeToken() released its token',
  'owned-escape-state-store': 'D: a long-lived State atom field must not keep an id whose only owner is a defer-freed local',
};

const marker_re = /^\s*\/\/\s*borrowed-atom:\s*(\S.*)$/;
const ownership_producer_re = /\.dup\(|\.internString\(|\.newSymbol\(|\.intern\(|\b[A-Za-z_]\w*Owned\(/;
const borrowed_read_re = /([A-Za-z_][\w.]*)\.payload\.\w+\.atom\b/g;
// Un-deferred token consumption: `advance()` frees `s.token` (qjs next_token
// -> free_token), `freeToken()` frees a lookahead token. `defer` lines are not
// release points: they run at scope exit, so the escape they create is a
// return or a state store, which rules A and B already own.
const release_re = /\badvance\s*\(|\bfreeToken\s*\(/;
const defer_line_re = /^\s*(?:defer|errdefer)\b/;

function toPosix(filePath) {
  return filePath.split(path.sep).join('/');
}

function normalizeRepoPath(filePath) {
  return toPosix(path.normalize(filePath)).replace(/^\.\//, '');
}

function fail(message) {
  console.error(`architecture borrowed-atom check failed: ${message}`);
  process.exit(1);
}

function allowKey(source, pattern) {
  return `${source} :: ${pattern}`;
}

function allowEntryKey(entry) {
  let key = allowKey(entry.source, entry.pattern);
  if (entry.fn !== undefined) key += ` :: fn ${entry.fn}`;
  if (entry.contains !== undefined) key += ` :: contains ${JSON.stringify(entry.contains)}`;
  return key;
}

function readAllowlist() {
  const raw = fs.readFileSync(allowlistPath, 'utf8');
  const entries = JSON.parse(raw);
  if (!Array.isArray(entries)) fail(`allowlist must be a JSON array: ${allowlistPath}`);
  if (entries.length > max_allowlist_entries) {
    fail(`allowlist has ${entries.length} entries; this rule caps it at ${max_allowlist_entries}`);
  }
  const seen = new Set();
  const entriesBySourcePattern = new Map();
  for (const [index, entry] of entries.entries()) {
    for (const field of ['source', 'pattern', 'reason', 'exit_milestone']) {
      if (typeof entry[field] !== 'string' || entry[field].length === 0) {
        fail(`allowlist entry ${index} is missing non-empty ${field}`);
      }
    }
    for (const selector of ['contains', 'fn']) {
      if (entry[selector] !== undefined && (typeof entry[selector] !== 'string' || entry[selector].length === 0)) {
        fail(`allowlist entry ${index} has a ${selector} selector that is not a non-empty string`);
      }
    }
    if (!known_patterns.has(entry.pattern)) {
      fail(`allowlist entry ${index} has unknown pattern "${entry.pattern}" (expected one of: ${[...known_patterns].join(', ')})`);
    }
    entry.source = normalizeRepoPath(entry.source);
    const key = allowEntryKey(entry);
    if (seen.has(key)) fail(`duplicate allowlist entry for ${key} (each entry covers exactly one finding)`);
    seen.add(key);
    const sourcePattern = allowKey(entry.source, entry.pattern);
    const group = entriesBySourcePattern.get(sourcePattern) ?? [];
    group.push(entry);
    entriesBySourcePattern.set(sourcePattern, group);
  }
  for (const [sourcePattern, group] of entriesBySourcePattern) {
    if (group.length > 1 && group.some((entry) => entry.contains === undefined && entry.fn === undefined)) {
      fail(`multiple allowlist entries for ${sourcePattern} must all provide distinct fn / contains selectors`);
    }
  }
  return entries;
}

function walk(dir, out) {
  for (const name of fs.readdirSync(dir).sort()) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) {
      walk(full, out);
    } else if (name.endsWith('.zig')) {
      out.push(normalizeRepoPath(path.relative(repoRoot, full)));
    }
  }
}

// Strip line comments and string literals so commented-out or quoted text
// never trips a rule. A line whose first token is `\\` is Zig multiline-string
// content, not code, so it is dropped whole.
function stripCode(rawLine) {
  if (/^\s*\\\\/.test(rawLine)) return '';
  let out = '';
  let inString = false;
  let inChar = false;
  for (let i = 0; i < rawLine.length; i += 1) {
    const c = rawLine[i];
    if (inString) {
      if (c === '\\') { out += ' '; i += 1; out += ' '; continue; }
      out += c === '"' ? '"' : ' ';
      if (c === '"') inString = false;
      continue;
    }
    if (inChar) {
      if (c === '\\') { out += ' '; i += 1; out += ' '; continue; }
      out += c === "'" ? "'" : ' ';
      if (c === "'") inChar = false;
      continue;
    }
    if (c === '/' && rawLine[i + 1] === '/') break;
    if (c === '"') { inString = true; out += c; continue; }
    if (c === "'") { inChar = true; out += c; continue; }
    out += c;
  }
  return out;
}

// True when the match at `index` is the value of the expression rather than an
// argument handed to a callee. `atomNameEquals(s, tok.payload.ident.atom, ..)`
// consumes the read inside the token's lifetime; `const a = tok.payload.ident.atom`
// keeps it. `@as(Atom, tok.payload.ident.atom)` keeps it too: builtins are
// transparent, so the scan continues outward through them.
//
// This is also what makes ownership provenance-aware. `.dup(x)` puts `x` in
// argument position, so a duped read is simply not a borrowing read -- and
// `return if (c) atoms.dup(a) else tok.payload.ident.atom` still reports the
// else branch, which a whole-statement "contains a dup" test would miss.
function isValuePosition(text, index) {
  let depth = 0;
  for (let i = index - 1; i >= 0; i -= 1) {
    const c = text[i];
    if (c === ')' || c === ']') depth += 1;
    else if (c === '(' || c === '[') {
      if (depth > 0) { depth -= 1; continue; }
      const callee = /(@?[\w.]+)$/.exec(text.slice(0, i).trimEnd());
      if (callee === null) return true;
      if (callee[1].startsWith('@')) continue;
      return false;
    }
  }
  return true;
}

function borrowedReadsIn(text, stats) {
  const found = [];
  borrowed_read_re.lastIndex = 0;
  let match;
  while ((match = borrowed_read_re.exec(text)) !== null) {
    if (stats !== undefined) stats.reads += 1;
    if (isValuePosition(text, match.index)) {
      if (stats !== undefined) stats.borrowingReads += 1;
      found.push({ owner: match[1], text: match[0] });
    }
  }
  return found;
}

function helperCallsIn(text, helpers) {
  const found = [];
  for (const helper of helpers) {
    const re = new RegExp(`\\b${helper}\\s*\\(`, 'g');
    let match;
    while ((match = re.exec(text)) !== null) {
      if (isValuePosition(text, match.index)) found.push(helper);
    }
  }
  return found;
}

// Any mention of the local, including argument position: for rule C that is
// exactly the dangerous read (`emitScopePutVar(catch_atom)` after advance).
function referencesLocal(text, name) {
  return new RegExp(`(?<![\\w.])${name}\\b`).test(text);
}

// The local appears as a value, not as an argument being consumed: what rules
// A / B and taint propagation need, so `atoms.dup(name)` does not count.
function referencesLocalValue(text, name) {
  const re = new RegExp(`(?<![\\w.])${name}\\b`, 'g');
  let match;
  while ((match = re.exec(text)) !== null) {
    if (isValuePosition(text, match.index)) return true;
  }
  return false;
}

// Taint only flows through identity-preserving expressions. `const hit = name
// == expected;` produces a bool, not the atom, so a comparison or boolean
// operator outside of any parenthesised sub-expression stops propagation
// (conditions live inside `if (...)`, which is stripped first).
function isIdentityPreserving(text) {
  let out = '';
  let depth = 0;
  for (const c of text) {
    if (c === '(' || c === '[') depth += 1;
    else if (c === ')' || c === ']') depth -= 1;
    else if (depth === 0) out += c;
  }
  return !/(==|!=|<=|>=|[<>!])|\band\b|\bor\b/.test(out);
}

// One logical statement per emitted record. Parens/brackets continue a
// statement, braces do not: block headers and block ends are their own
// statements so nested statements stay separate.
function statementsOf(codeLines, startLine, endLine) {
  const statements = [];
  let buffer = '';
  let bufferStart = startLine;
  let depth = 0;
  for (let i = startLine; i <= endLine; i += 1) {
    const trimmed = codeLines[i].trim();
    if (trimmed.length === 0) continue;
    if (buffer.length === 0) bufferStart = i;
    buffer = buffer.length === 0 ? trimmed : `${buffer} ${trimmed}`;
    for (const c of trimmed) {
      if (c === '(' || c === '[') depth += 1;
      else if (c === ')' || c === ']') depth -= 1;
    }
    if (depth <= 0 && /[;{}]$/.test(trimmed)) {
      statements.push({ text: buffer, startLine: bufferStart, endLine: i });
      buffer = '';
      depth = 0;
    }
  }
  if (buffer.length !== 0) statements.push({ text: buffer, startLine: bufferStart, endLine: endLine });
  return statements;
}

function braceDelta(line) {
  return (line.match(/\{/g) ?? []).length - (line.match(/\}/g) ?? []).length;
}

function functionsOf(codeLines) {
  const fns = [];
  const open = [];
  for (const [i, line] of codeLines.entries()) {
    const match = /^(\s*)(?:pub\s+)?(?:inline\s+|noinline\s+|export\s+|extern\s+)*fn\s+(\w+)\s*\(/.exec(line);
    if (match !== null) {
      // `fn foo() void {}` opens and closes on one line; treating it as open
      // would hand its body to the next function.
      if (line.includes('{') && braceDelta(line) <= 0) {
        fns.push({ name: match[2], indent: match[1].length, startLine: i, endLine: i });
        continue;
      }
      open.push({ name: match[2], indent: match[1].length, startLine: i });
      continue;
    }
    if (open.length !== 0 && /^\s*\}/.test(line)) {
      const indent = line.length - line.trimStart().length;
      while (open.length !== 0 && open[open.length - 1].indent >= indent) {
        const fn = open.pop();
        fns.push({ ...fn, endLine: i });
      }
    }
  }
  for (const fn of open) fns.push({ ...fn, endLine: codeLines.length - 1 });
  fns.sort((a, b) => a.startLine - b.startLine);
  return fns;
}

// Receivers this function binds to `*State` (`s: *State`, `self: *State`).
// The store rules require one of these, so a neighbouring struct's own
// `self.<atom_field> = ...` is never mistaken for parser state.
function stateReceivers(codeLines, fn) {
  const names = new Set();
  for (let i = fn.startLine; i <= Math.min(fn.endLine, fn.startLine + 16); i += 1) {
    const line = codeLines[i];
    const re = /(\w+)\s*:\s*\*(?:const\s+)?State\b/g;
    let match;
    while ((match = re.exec(line)) !== null) names.add(match[1]);
    if (/\{\s*$/.test(line)) break;
  }
  return names;
}

// Lines inside a `defer { ... }` / `errdefer { ... }` block. Those run at scope
// exit, so a `freeToken` there is not an in-line release point and a read there
// is not an in-line use -- rules A / B already own the escapes a scope-exit
// release creates.
function deferBlockLines(codeLines, startLine, endLine) {
  const flags = new Array(endLine + 1).fill(false);
  let depth = 0;
  let active = false;
  let baseDepth = 0;
  for (let i = startLine; i <= endLine; i += 1) {
    const line = codeLines[i];
    if (!active && /^\s*(?:defer|errdefer)\b/.test(line) && braceDelta(line) > 0) {
      active = true;
      baseDepth = depth;
      flags[i] = true;
      depth += braceDelta(line);
      continue;
    }
    if (active) {
      flags[i] = true;
      depth += braceDelta(line);
      if (depth <= baseDepth) active = false;
      continue;
    }
    depth += braceDelta(line);
  }
  return flags;
}

// Names declared as `Atom` / `?Atom` at struct scope in this file. Collected
// from struct scope only -- lines inside a function body are skipped, so a
// multi-line parameter list never looks like a field -- and paired with the
// `*State` receiver test above, so this selects the long-lived parser-State
// atom carriers and covers a newly added field the day it appears.
function atomFieldNames(codeLines, fns) {
  const inFunction = new Array(codeLines.length).fill(false);
  for (const fn of fns) {
    for (let i = fn.startLine; i <= fn.endLine; i += 1) inFunction[i] = true;
  }
  const fields = new Set();
  for (const [i, line] of codeLines.entries()) {
    if (inFunction[i]) continue;
    const match = /^\s+(\w+)\s*:\s*\??Atom\s*(?:=|,)/.exec(line);
    if (match !== null) fields.add(match[1]);
  }
  return fields;
}

function hasMarkerAbove(rawLines, lineIndex) {
  for (let i = lineIndex - 1; i >= 0; i -= 1) {
    const raw = rawLines[i];
    if (raw.trim().length === 0) return false;
    const match = marker_re.exec(raw);
    if (match !== null) return true;
    return false;
  }
  return false;
}

function analyzeFile(source, state) {
  const rawLines = fs.readFileSync(path.join(repoRoot, source), 'utf8').split('\n');
  const codeLines = rawLines.map(stripCode);
  const fns = functionsOf(codeLines);
  const fields = atomFieldNames(codeLines, fns);
  const findings = [];
  const stats = { reads: 0, borrowingReads: 0, locals: 0 };

  // Pass A: which same-file helpers hand a borrowed atom back to their caller.
  // Fixed point, so `f -> g -> token` propagates.
  const helpers = new Set();
  for (let round = 0; round < fns.length + 1; round += 1) {
    const before = helpers.size;
    for (const fn of fns) {
      if (helpers.has(fn.name)) continue;
      const analysis = analyzeFunction(fn, rawLines, codeLines, fields, helpers, { helperScanOnly: true });
      if (analysis.returnsBorrowed) helpers.add(fn.name);
    }
    if (helpers.size === before) break;
  }

  // Pass B: escapes.
  for (const fn of fns) {
    const analysis = analyzeFunction(fn, rawLines, codeLines, fields, helpers, { helperScanOnly: false, stats });
    for (const finding of analysis.findings) findings.push({ ...finding, source });
  }

  state.helpersByFile.set(source, [...helpers].sort());
  return { findings, stats, functionCount: fns.length };
}

function analyzeFunction(fn, rawLines, codeLines, fields, helpers, options) {
  const statements = statementsOf(codeLines, fn.startLine, fn.endLine);
  // Skip the signature line: a function called `...Owned` would otherwise
  // satisfy the "produces an owner" probe with its own name.
  const bodyText = codeLines.slice(fn.startLine + 1, fn.endLine + 1).join('\n');
  const fnProducesOwner = ownership_producer_re.test(bodyText);
  // The `...Owned` convention exempts rule A for a forwarded borrow (a helper
  // result or a tainted local, where the promise cannot be checked statically)
  // and only when the body really produces an owner. It never exempts a
  // returned token payload read: that is the `ada949be` shape itself, and no
  // name may legalise it.
  const ownedExemptForward = fn.name.endsWith('Owned') && fnProducesOwner;
  const receivers = stateReceivers(codeLines, fn);
  const inDefer = deferBlockLines(codeLines, fn.startLine, fn.endLine);

  // Locals bound to a borrowed atom, and locals whose only owner is a
  // `defer ...free(local)` in this function.
  // `borrowedLocals` is what is live at the current statement (taint, returns,
  // stores). `borrowSites` keeps every borrowing site with the window it owns,
  // so a same-named local rebound later in another branch neither steals nor
  // erases an earlier site's finding.
  const borrowedLocals = new Map();
  const borrowSites = [];
  const deferFreedLocals = new Set();
  const restoredFields = new Set();
  const releaseLines = [];
  let returnsBorrowed = false;
  const escapes = new Map();

  const noteEscape = (key, origin, kind, line) => {
    const entry = escapes.get(key) ?? { origin, kinds: [] };
    entry.kinds.push({ kind, line });
    escapes.set(key, entry);
  };

  for (const statement of statements) {
    const { text, startLine } = statement;
    if (defer_line_re.test(text) || inDefer[startLine]) {
      const freed = /free\(\s*([A-Za-z_]\w*)\s*\)/.exec(text);
      if (freed !== null) deferFreedLocals.add(freed[1]);
      const restored = /\b(\w+)\.(\w+)\s*=\s*saved_\w+/.exec(text);
      if (restored !== null && receivers.has(restored[1])) restoredFields.add(restored[2]);
      continue;
    }
    const restored = /^(\w+)\.(\w+)\s*=\s*saved_\w+/.exec(text);
    if (restored !== null && receivers.has(restored[1])) restoredFields.add(restored[2]);
    if (release_re.test(text)) releaseLines.push(startLine);
  }

  for (const statement of statements) {
    const { text, startLine } = statement;
    if (defer_line_re.test(text) || inDefer[startLine]) continue;
    borrowedReadsIn(text, options.stats);

    // Borrowed binding: `const x = <borrowed>` / `var x = <borrowed>` / a plain
    // reassignment `x = <borrowed>`. A binding is not an escape by itself; it
    // is what the escape rules track. Ownership is decided by position, so
    // `const x = atoms.dup(t.payload.ident.atom)` never taints x, and an owned
    // reassignment clears an earlier taint.
    const binding = /^(?:(?:const|var)\s+)?(\w+)(?:\s*:[^=]*)?\s*=\s*([\s\S]*)$/.exec(text);
    if (binding !== null && !/^(?:if|while|for|switch|return|try|defer|errdefer)$/.test(binding[1])) {
      const name = binding[1];
      const rhs = binding[2];
      const isDeclaration = /^(?:const|var)\s/.test(text);
      const rhsReads = borrowedReadsIn(rhs);
      const rhsHelpers = helperCallsIn(rhs, helpers);
      // Local-to-local taint only through a declaration: a plain reassignment
      // of an already-tracked borrow (`target_atom = atom_id;`) would just
      // report the same borrow a second time under another name.
      const rhsTainted = isDeclaration && isIdentityPreserving(rhs) &&
        [...borrowedLocals.keys()].some((local) => referencesLocalValue(rhs, local));
      const previous = borrowedLocals.get(name);
      if (rhsReads.length !== 0 || rhsHelpers.length !== 0 || rhsTainted) {
        if (previous !== undefined) previous.endLine = startLine - 1;
        if (options.stats !== undefined) options.stats.locals += 1;
        const site = { name, line: startLine, text, endLine: fn.endLine };
        borrowedLocals.set(name, site);
        borrowSites.push(site);
      } else if (previous !== undefined) {
        // Rebinding to something owned ends the borrow window: `nm = dup(nm)`
        // and `const nm = <owned>` both retire the earlier site.
        previous.endLine = startLine - 1;
        borrowedLocals.delete(name);
      }
    }

    // Rule A: return.
    const returnMatches = [...text.matchAll(/\breturn\b([^;]*)/g)];
    for (const returnMatch of returnMatches) {
      const expr = returnMatch[1];
      if (expr.trim().length === 0) continue;
      const exprReads = borrowedReadsIn(expr);
      const exprHelpers = helperCallsIn(expr, helpers);
      const localHit = [...borrowedLocals.entries()].find(([local]) => referencesLocalValue(expr, local));
      if (exprReads.length === 0 && exprHelpers.length === 0 && localHit === undefined) continue;
      returnsBorrowed = true;
      if (options.helperScanOnly) break;
      if (ownedExemptForward && exprReads.length === 0) continue;
      const origin = localHit === undefined
        ? { line: startLine, text }
        : { line: localHit[1].line, text: localHit[1].text };
      if (hasMarkerAbove(rawLines, startLine)) continue;
      noteEscape(`${origin.line}`, origin, 'borrowed-return', startLine);
    }
    if (options.helperScanOnly) continue;

    // Rules B and D: store into a long-lived State atom field.
    const store = /^(\w+)\.(\w+)\s*=\s*([\s\S]*?);?$/.exec(text);
    if (store !== null && receivers.has(store[1]) && fields.has(store[2])) {
      const field = store[2];
      const rhs = store[3];
      const rhsBorrowedLocal = [...borrowedLocals.entries()].find(([local]) => referencesLocalValue(rhs, local));
      const rhsReads = borrowedReadsIn(rhs);
      const rhsHelpers = helperCallsIn(rhs, helpers);
      if (rhsBorrowedLocal !== undefined || rhsReads.length !== 0 || rhsHelpers.length !== 0) {
        const origin = rhsBorrowedLocal === undefined
          ? { line: startLine, text }
          : { line: rhsBorrowedLocal[1].line, text: rhsBorrowedLocal[1].text };
        if (!hasMarkerAbove(rawLines, startLine)) {
          noteEscape(`${origin.line}`, origin, 'borrowed-state-store', startLine);
        }
      } else if (!restoredFields.has(field)) {
        const deferFreed = [...deferFreedLocals].find((local) => referencesLocal(rhs, local));
        if (deferFreed !== undefined && !hasMarkerAbove(rawLines, startLine)) {
          noteEscape(`store:${startLine}`, { line: startLine, text }, 'owned-escape-state-store', startLine);
        }
      }
    }
  }

  if (options.helperScanOnly) return { returnsBorrowed, findings: [] };

  // Rule C: read after an un-deferred release, inside the window this site owns.
  for (const site of borrowSites) {
    const release = releaseLines.find((line) => line > site.line && line <= site.endLine);
    if (release === undefined) continue;
    let useLine;
    for (const statement of statementsOf(codeLines, release + 1, site.endLine)) {
      if (defer_line_re.test(statement.text) || inDefer[statement.startLine]) continue;
      if (referencesLocal(statement.text, site.name)) { useLine = statement.startLine; break; }
    }
    if (useLine === undefined) continue;
    // The borrowing line is the natural place to state a deliberate borrow that
    // outlives the token, so rule C accepts the marker there as well as on the
    // use. Rules A and B accept it only on the escaping line.
    if (hasMarkerAbove(rawLines, site.line) || hasMarkerAbove(rawLines, useLine)) continue;
    noteEscape(`${site.line}`, { line: site.line, text: site.text }, 'borrowed-use-after-release', useLine);
  }

  const findings = [];
  for (const [, entry] of escapes) {
    const kinds = entry.kinds;
    const pattern = pattern_priority.find((candidate) => kinds.some((kind) => kind.kind === candidate));
    const detail = pattern_priority
      .filter((candidate) => kinds.some((kind) => kind.kind === candidate))
      .map((candidate) => `${candidate}@${kinds.filter((kind) => kind.kind === candidate).map((kind) => kind.line + 1).join(',')}`)
      .join(' ');
    findings.push({
      lineno: entry.origin.line + 1,
      pattern,
      fn: fn.name,
      text: entry.origin.text,
      detail,
    });
  }
  findings.sort((a, b) => a.lineno - b.lineno);
  return { returnsBorrowed, findings };
}

function entryMatchesFinding(entry, finding) {
  return entry.source === finding.source &&
    entry.pattern === finding.pattern &&
    (entry.fn === undefined || entry.fn === finding.fn) &&
    (entry.contains === undefined || finding.text.includes(entry.contains));
}

const allowlist = readAllowlist();

const files = [];
walk(path.join(repoRoot, 'src'), files);

const state = { helpersByFile: new Map() };
const findings = [];
const totals = { reads: 0, borrowingReads: 0, locals: 0 };
let functionCount = 0;
let scannedFiles = 0;
for (const source of files) {
  if (source.startsWith('src/tests/')) continue;
  scannedFiles += 1;
  const result = analyzeFile(source, state);
  findings.push(...result.findings);
  for (const key of Object.keys(totals)) totals[key] += result.stats[key];
  functionCount += result.functionCount;
}

if (process.argv.includes('--list')) {
  for (const finding of findings) {
    console.log(`${finding.source}:${finding.lineno}\t${finding.pattern}\t${finding.fn}\t${finding.detail}\t${finding.text}`);
  }
  for (const [source, helpers] of state.helpersByFile) {
    if (helpers.length !== 0) console.log(`# borrowing helpers in ${source}: ${helpers.join(', ')}`);
  }
}

const matchesByEntry = new Map();
for (const entry of allowlist) {
  matchesByEntry.set(entry, findings.filter((finding) => entryMatchesFinding(entry, finding)));
}
const stale = allowlist.filter((entry) => matchesByEntry.get(entry).length === 0);
const nonUnique = allowlist.filter((entry) => matchesByEntry.get(entry).length > 1);
const ownersByFinding = new Map(findings.map((finding) => [finding, []]));
for (const entry of allowlist) {
  for (const finding of matchesByEntry.get(entry)) ownersByFinding.get(finding).push(entry);
}
const overlapping = findings.filter((finding) => ownersByFinding.get(finding).length > 1);
const violations = findings.filter((finding) => ownersByFinding.get(finding).length === 0);

if (violations.length !== 0 || stale.length !== 0 || nonUnique.length !== 0 || overlapping.length !== 0) {
  if (violations.length !== 0) {
    console.error('\nBorrowed-atom rule violations:');
    for (const violation of violations) {
      console.error(`  ${violation.source}:${violation.lineno}: in ${violation.fn}: ${violation.text}`);
      console.error(`    rule ${rule_text[violation.pattern]}`);
      console.error(`    escapes: ${violation.detail}`);
      console.error('    fix: dup in the escaping expression, rename the function ...Owned, or');
      console.error('         write "// borrowed-atom: <reason>" above the line');
    }
  }
  if (stale.length !== 0) {
    console.error('\nStale borrowed-atom allowlist entries (no matching finding):');
    for (const entry of stale) {
      console.error(`  ${allowEntryKey(entry)}`);
      console.error(`    exit_milestone: ${entry.exit_milestone}`);
    }
  }
  if (nonUnique.length !== 0) {
    console.error('\nNon-unique borrowed-atom allowlist entries (selector matches more than one finding):');
    for (const entry of nonUnique) {
      console.error(`  ${allowEntryKey(entry)}`);
      console.error(`    matched findings: ${matchesByEntry.get(entry).length}`);
    }
  }
  if (overlapping.length !== 0) {
    console.error('\nOverlapping borrowed-atom allowlist entries (one finding has multiple owners):');
    for (const finding of overlapping) {
      console.error(`  ${finding.source}:${finding.lineno}: ${finding.text}`);
      for (const entry of ownersByFinding.get(finding)) console.error(`    ${allowEntryKey(entry)}`);
    }
  }
  process.exit(1);
}

console.log(`architecture borrowed-atom check ok (${scannedFiles} Zig files / ${functionCount} functions scanned, ${totals.reads} token-atom read(s) of which ${totals.borrowingReads} in value position, ${totals.locals} borrowed local(s) tracked, ${findings.length} escape(s) found, ${allowlist.length}/${max_allowlist_entries} allowlisted)`);
