#!/usr/bin/env python3
"""Report top-level declarations with no reference anywhere in the tree.

    python3 tools/maintainability/dead_decls.py $(find src -name '*.zig' \
        -not -path 'src/tests/*' -not -name 'data.zig' | sort)

Reachability is established by DELETION, not by this script: it only proposes
candidates. Delete them, build, and let Zig refuse anything still referenced.

Two properties of the predicate are load-bearing (docs/code-volume.md):

  * Deletion cascades. A declaration whose only reference was itself deleted
    becomes dead in turn, so re-run to a fixed point.

  * A non-`pub` top-level declaration is only visible inside its own file, so
    its hits are counted file-locally. Counting tree-wide would let a
    same-named declaration elsewhere keep a dead private one alive -- that is
    how a 143-line unused Promise combinator survived a whole sweep.

The corpus includes docs, tests and tooling, so a name mentioned only in a doc
comment counts as referenced and is kept. Comptime-assembled names are
invisible to any text scan: exclude `src/libs/unicode/data.zig`, whose property
tables are reached via `@field(@This(), "unicode_prop_" ++ name ++ "_table")`.

Struct fields are deliberately out of scope -- they are layout-bearing in this
repository and the declaration anchor excludes them by construction.
"""

import os, re, sys, collections
corpus = {}
for root, d, fs in os.walk('.'):
    if any(x in root for x in ('/.git', '/.zig-cache', '/zig-out', '/test262/test', '/.scratch', '/worktrees')): continue
    for f in fs:
        if f.endswith(('.zig', '.js', '.json', '.md', '.yml', '.sh', '.py', '.txt')):
            p = os.path.join(root, f)
            try: corpus[p] = open(p, encoding='utf8', errors='replace').read()
            except: pass

word = re.compile(r'\w+')
total = collections.Counter()
local = {}
for p, txt in corpus.items():
    c = collections.Counter(word.findall(txt))
    local[p] = c
    total.update(c)

decl = re.compile(r'^(?P<pub>pub )?(?:export )?(?:noinline |inline )?(?:threadlocal )?(?:fn|const|var) (?P<name>\w+)\b')

def strip_line(l):
    out = []; i = 0; n = len(l)
    while i < n:
        c = l[i]
        if c == '/' and i+1 < n and l[i+1] == '/': break
        if c == '"':
            i += 1
            while i < n:
                if l[i] == '\\': i += 2; continue
                if l[i] == '"': i += 1; break
                i += 1
            continue
        if c == "'":
            i += 1
            while i < n:
                if l[i] == '\\': i += 2; continue
                if l[i] == "'": i += 1; break
                i += 1
            continue
        out.append(c); i += 1
    return ''.join(out)

def span_of(lines, i):
    depth = 0; started = False
    for j in range(i, len(lines)):
        s = strip_line(lines[j])
        for c in s:
            if c in '{([': depth += 1; started = True
            elif c in '})]': depth -= 1
        if depth <= 0 and (s.rstrip().endswith(';') or (started and s.rstrip().endswith('}'))):
            return j - i + 1
    return 1

def scan(target):
    """返回 [(name, is_pub, line0, span)]，判据分 pub / 非 pub 两档"""
    key = ('./'+target) if ('./'+target) in corpus else target
    if key not in corpus: return []
    lines = corpus[key].split('\n')
    dead = []
    for i, l in enumerate(lines):
        m = decl.match(l)
        if not m: continue
        name = m.group('name')
        is_pub = bool(m.group('pub'))
        # 非 pub 的顶层声明在 Zig 里只有同文件可见：只数本文件
        hits = (total[name] if is_pub else local[key][name]) - 1
        if hits > 0: continue
        dead.append((name, is_pub, i, span_of(lines, i)))
    return dead

if __name__ == '__main__':
    grand = 0; grandn = 0; rows = []
    for target in sys.argv[1:]:
        dead = scan(target)
        if not dead: continue
        tot = sum(d[3] for d in dead)
        grand += tot; grandn += len(dead)
        rows.append((tot, target, dead))
    rows.sort(reverse=True)
    for tot, target, dead in rows:
        print(f"{target}: 零引用声明 {len(dead)} 个, 约 {tot} 行")
        for name, is_pub, ln, span in dead:
            print(f"    {'pub ' if is_pub else '    '}{name:48s} :{ln+1:<6} {span:>4}行")
    print(f"\n=== 合计 {grandn} 个声明, 约 {grand} 行 ===")
