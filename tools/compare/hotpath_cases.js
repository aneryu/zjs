const supported = (name, quickjsName, category, notes, source) => ({
    name,
    quickjsName,
    category,
    expectedStatus: 'supported',
    notes,
    source: source.join('\n'),
});

export const cases = [
    supported('math_min_loop', 'math_min_loop', 'math', 'Hotpath Math.min loop covering global lookup, property lookup, native call, and loop execution.', [
        'let sum = 0;',
        'for (let i = 0; i < 60000; i++) sum += Math.min(i, 500);',
        'print(sum);',
    ]),
    supported('regexp_test_cached_loop', 'regexp_test_cached_loop', 'regexp', 'Hotpath cached RegExp.prototype.test loop on one RegExp object.', [
        'const r = /a+b/;',
        'let c = 0;',
        'for (let i = 0; i < 100000; i++) if (r.test("aaab")) c++;',
        'print(c);',
    ]),
    supported('regexp_literal_test_loop', 'regexp_literal_test_loop', 'regexp', 'Hotpath RegExp literal test loop that keeps literal evaluation visible.', [
        'let c = 0;',
        'for (let i = 0; i < 100000; i++) if (/a+b/.test("aaab")) c++;',
        'print(c);',
    ]),
    supported('array_push_loop', 'array_push_loop', 'array', 'Hotpath Array.prototype.push loop on a dense array.', [
        'const a = [];',
        'for (let i = 0; i < 100000; i++) a.push(i);',
        'print(a.length);',
    ]),
    supported('array_sparse_length_loop', 'array_sparse_length_loop', 'array', 'Hotpath sparse array literal length loop with a hole.', [
        'let s = 0;',
        'for (let i = 0; i < 50000; i++) {',
        '  const a = [1, , 3];',
        '  s += a.length;',
        '}',
        'print(s);',
    ]),
    supported('map_set_get_loop', 'map_set_get_loop', 'collection', 'Hotpath Map string-key set/get loop.', [
        'const m = new Map();',
        'for (let i = 0; i < 10000; i++) m.set("k" + i, i);',
        'let s = 0;',
        'for (let i = 0; i < 10000; i++) s += m.get("k" + i);',
        'print(s);',
    ]),
    supported('global_write_loop', 'global_write_loop', 'global', 'Hotpath strict global write loop.', [
        '"use strict";',
        'var g = 0;',
        'for (let i = 0; i < 100000; i++) g = i;',
        'print(g);',
    ]),
    supported('prop_read_mono_loop', 'prop_read_mono_loop', 'object', 'Hotpath monomorphic object property read loop used as an IC sentinel.', [
        'const o = { a: 1, b: 2, c: 3 };',
        'let s = 0;',
        'for (let i = 0; i < 1000000; i++) s += o.a;',
        'print(s);',
    ]),
    // The cases below intentionally use function bodies that the
    // simple-numeric bytecode fusion cannot recognize, so they always
    // exercise the real frame push/pop and call machinery.
    supported('fib_rec', 'fib_rec', 'function', 'Hotpath recursive fibonacci; deep real call stacks that bypass call fusion.', [
        'function fib(n) {',
        '  if (n < 2) return n;',
        '  const a = fib(n - 1);',
        '  const b = fib(n - 2);',
        '  return a + b;',
        '}',
        'print(fib(24));',
    ]),
    supported('call_body_loop', 'call_body_loop', 'function', 'Hotpath call loop with a multi-statement body and locals that bypass call fusion.', [
        'function f(a, b) {',
        '  let t = a + b;',
        '  t = t * 2;',
        '  if (t < 0) t = -t;',
        '  return t - b;',
        '}',
        'let s = 0;',
        'for (let i = 0; i < 300000; i++) s += f(i, 3);',
        'print(s);',
    ]),
    supported('method_call_loop', 'method_call_loop', 'function', 'Hotpath monomorphic method call loop with a non-fusable body.', [
        'const o = {',
        '  v: 7,',
        '  m(x) {',
        '    let r = this.v + x;',
        '    if (r > 1000000000) r = 0;',
        '    return r;',
        '  },',
        '};',
        'let s = 0;',
        'for (let i = 0; i < 300000; i++) s += o.m(i);',
        'print(s);',
    ]),
    supported('alloc_call_loop', 'alloc_call_loop', 'function', 'Hotpath call loop allocating an object per call to expose frame plus allocation cost.', [
        'function make(x) {',
        '  const o = { a: x, b: x + 1 };',
        '  return o.a + o.b;',
        '}',
        'let s = 0;',
        'for (let i = 0; i < 200000; i++) s += make(i);',
        'print(s);',
    ]),
];

export function categories() {
    return Array.from(new Set(cases.map((item) => item.category))).sort();
}
