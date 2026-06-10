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
];

export function categories() {
    return Array.from(new Set(cases.map((item) => item.category))).sort();
}
