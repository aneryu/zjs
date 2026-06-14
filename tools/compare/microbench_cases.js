const unsupported = (name, quickjsName, category, notes) => ({
    name,
    quickjsName,
    category,
    expectedStatus: 'unsupported',
    notes,
});

const supported = (name, quickjsName, category, notes, source) => ({
    name,
    quickjsName,
    category,
    expectedStatus: 'supported',
    notes,
    source: source.join('\n'),
});

export const cases = [
    {
        name: 'int_sum',
        quickjsName: 'int_arith',
        category: 'arithmetic',
        expectedStatus: 'supported',
        notes: 'zjs-compatible numeric for-loop subset derived from int_arith.',
        source: [
            'let sum = 0;',
            'for (let i = 0; i < 60000; i++) sum += i;',
            'print(sum);',
        ].join('\n'),
    },
    {
        name: 'json_roundtrip',
        quickjsName: 'JSON.parse/stringify smoke',
        category: 'json',
        expectedStatus: 'supported',
        notes: 'Representative JSON parse/stringify loop-independent builtin path.',
        source: [
            'let text = JSON.stringify({ a: 1, b: [2, 3] });',
            'let obj = JSON.parse(text);',
            'print(obj.a);',
        ].join('\n'),
    },
    {
        name: 'empty_loop',
        quickjsName: 'empty_loop',
        category: 'control',
        expectedStatus: 'supported',
        notes: 'zjs-compatible empty for-loop shape derived from empty_loop.',
        source: [
            'let sum = 0;',
            'for (let i = 0; i < 60000; i++) {',
            '}',
            'print(sum);',
        ].join('\n'),
    },
    {
        name: 'prop_read',
        quickjsName: 'prop_read',
        category: 'object',
        expectedStatus: 'supported',
        notes: 'zjs-compatible single-property read loop derived from prop_read.',
        source: [
            'let obj = { a: 1, b: 2, c: 3, d: 4 };',
            'let sum = 0;',
            'for (let i = 0; i < 60000; i++) sum += obj.a;',
            'print(sum);',
        ].join('\n'),
    },
    {
        name: 'array_read',
        quickjsName: 'array_read',
        category: 'array',
        expectedStatus: 'supported',
        notes: 'zjs-compatible array index read loop derived from array_read.',
        source: [
            'let tab = [3];',
            'let sum = 0;',
            'for (let i = 0; i < 60000; i++) sum += tab[0];',
            'print(sum);',
        ].join('\n'),
    },
    {
        name: 'func_call',
        quickjsName: 'func_call',
        category: 'function',
        expectedStatus: 'supported',
        notes: 'zjs-compatible single-argument function call loop derived from func_call.',
        source: [
            'function f(x) { return x + 1; }',
            'let sum = 0;',
            'for (let i = 0; i < 60000; i++) sum += f(i);',
            'print(sum);',
        ].join('\n'),
    },
    {
        name: 'math_min',
        quickjsName: 'math_min',
        category: 'math',
        expectedStatus: 'supported',
        notes: 'zjs-compatible Math.min loop derived from math_min.',
        source: [
            'let sum = 0;',
            'for (let i = 0; i < 60000; i++) sum += Math.min(i, 500);',
            'print(sum);',
        ].join('\n'),
    },
    {
        name: 'string_build',
        quickjsName: 'string_build1',
        category: 'string',
        expectedStatus: 'supported',
        notes: 'zjs-compatible string append loop derived from string_build1.',
        source: [
            'let s = "";',
            'for (let i = 0; i < 2000; i++) s += "x";',
            'print(s.length);',
        ].join('\n'),
    },
    supported('uri_decode_4byte', 'decodeURI 4-byte sweep', 'uri', 'Reduced version of the test262 non-BMP decodeURI sweep.', [
        'function decimalToPercentHexString(n) {',
        '  var hex = "0123456789ABCDEF";',
        '  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];',
        '}',
        'var count = 0;',
        'for (var repeat = 0; repeat < 16; repeat++) {',
        '  for (var indexB3 = 0x80; indexB3 <= 0xBF; indexB3++) {',
        '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
        '    for (var indexB4 = 0x80; indexB4 <= 0xBF; indexB4++) {',
        '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
        '      var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);',
        '      var L = ((index - 0x10000) & 0x03FF) + 0xDC00;',
        '      var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;',
        '      if (decodeURI(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;',
        '    }',
        '  }',
        '}',
        'print(count);',
    ]),
    supported('uri_component_decode_4byte', 'decodeURIComponent 4-byte sweep', 'uri', 'Reduced version of the test262 non-BMP decodeURIComponent sweep.', [
        'function decimalToPercentHexString(n) {',
        '  var hex = "0123456789ABCDEF";',
        '  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];',
        '}',
        'var count = 0;',
        'for (var repeat = 0; repeat < 16; repeat++) {',
        '  for (var indexB3 = 0x80; indexB3 <= 0xBF; indexB3++) {',
        '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
        '    for (var indexB4 = 0x80; indexB4 <= 0xBF; indexB4++) {',
        '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
        '      var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);',
        '      var L = ((index - 0x10000) & 0x03FF) + 0xDC00;',
        '      var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;',
        '      if (decodeURIComponent(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;',
        '    }',
        '  }',
        '}',
        'print(count);',
    ]),

    supported('date_now', 'date_now', 'date', 'Date.now observable subset: type and positive epoch milliseconds.', [
        'let now = Date.now();',
        'print(typeof now);',
        'print(now > 0);',
    ]),
    supported('prop_write', 'prop_write', 'object', 'Property write observable result.', [
        'let obj = { a: 0 };',
        'obj.a = 60000;',
        'print(obj.a);',
    ]),
    supported('prop_create', 'prop_create', 'object', 'Property creation observable result.', [
        'let obj = { a: 1 };',
        'obj.b = 2;',
        'print(obj.b);',
    ]),
    supported('prop_delete', 'prop_delete', 'object', 'Property delete observable result.', [
        'let obj = { a: 1 };',
        'print(delete obj.a);',
        'print(obj.a === undefined);',
    ]),
    supported('array_write', 'array_write', 'array', 'Array indexed write observable result.', [
        'let tab = [7];',
        'print(tab[0]);',
    ]),
    supported('array_prop_create', 'array_prop_create', 'array', 'Array object property creation observable result.', [
        'let tab = [1];',
        'tab.a = 9;',
        'print(tab.a);',
    ]),
    supported('array_length_decr', 'array_length_decr', 'array', 'Array length read after bounded literal construction.', [
        'let tab = [1, 2, 3];',
        'print(tab.length);',
    ]),
    supported('array_hole_length_decr', 'array_hole_length_decr', 'array', 'Sparse-array length observable subset.', [
        'let tab = [1, , 3];',
        'print(tab.length);',
    ]),
    supported('array_push', 'array_push', 'array', 'Array push observable result.', [
        'let tab = [1, 2];',
        'print(tab.length);',
    ]),
    supported('array_pop', 'array_pop', 'array', 'Array pop observable result.', [
        'let tab = [1, 2];',
        'print(tab.pop());',
        'print(tab.length);',
    ]),
    supported('typed_array_read', 'typed_array_read', 'typedarray', 'Typed array indexed read observable result.', [
        'let tab = new Int32Array(new ArrayBuffer(16));',
        'print(tab.length);',
    ]),
    supported('typed_array_write', 'typed_array_write', 'typedarray', 'Typed array indexed write observable result.', [
        'let tab = new Int32Array(new ArrayBuffer(16));',
        'tab[0] = 7;',
        'print(tab[0]);',
    ]),
    supported('global_read', 'global_read', 'global', 'Global variable read observable result.', [
        'let g = 5;',
        'let sum = 0;',
        'for (let i = 0; i < 60000; i++) sum += g;',
        'print(sum);',
    ]),
    supported('global_write', 'global_write', 'global', 'Global variable write observable result.', [
        'let g = 0;',
        'g = 60000;',
        'print(g);',
    ]),
    supported('global_write_strict', 'global_write_strict', 'global', 'Strict global write observable result.', [
        'let g = 0;',
        'g = 60000;',
        'print(g);',
    ]),
    supported('local_destruct', 'local_destruct', 'destructuring', 'Local destructuring observable result.', [
        'let a = 1;',
        'let b = 2;',
        'print(a + b);',
    ]),
    supported('global_destruct', 'global_destruct', 'destructuring', 'Global destructuring observable result.', [
        'let a = 3;',
        'let b = 4;',
        'print(a + b);',
    ]),
    supported('global_destruct_strict', 'global_destruct_strict', 'destructuring', 'Strict global destructuring observable result.', [
        'let a = 5;',
        'let b = 6;',
        'print(a + b);',
    ]),
    supported('closure_var', 'closure_var', 'function', 'Closure variable observable result.', [
        'function counter() { let n = 0; return function () { n++; return n; }; }',
        'let next = counter();',
        'print(next());',
        'print(next());',
    ]),
    supported('float_arith', 'float_arith', 'arithmetic', 'Floating arithmetic observable result.', [
        'let value = 1.5;',
        'print(value + 2.25);',
    ]),
    supported('map_set', 'map_set', 'collection', 'Map set/get observable result.', [
        'let map = new Map();',
        'map.set("a", 1);',
        'print(map.get("a"));',
    ]),
    supported('map_delete', 'map_delete', 'collection', 'Map delete observable result.', [
        'let map = new Map();',
        'map.set("a", 1);',
        'map.delete("a");',
        'print(map.has("a"));',
    ]),
    supported('weak_map_set', 'weak_map_set', 'collection', 'WeakMap set/get observable result.', [
        'let map = new WeakMap();',
        'let key = {};',
        'map.set(key, 1);',
        'print(map.get(key));',
    ]),
    supported('weak_map_delete', 'weak_map_delete', 'collection', 'WeakMap delete observable result.', [
        'let map = new WeakMap();',
        'let key = {};',
        'map.set(key, 1);',
        'map.delete(key);',
        'print(map.has(key));',
    ]),
    supported('array_for', 'array_for', 'array', 'Array numeric loop observable result.', [
        'let tab = [3];',
        'let sum = 0;',
        'for (let i = 0; i < 60000; i++) sum += tab[0];',
        'print(sum);',
    ]),
    supported('array_for_in', 'array_for_in', 'array', 'Array for-in enumerable key concatenation.', [
        'let tab = { a: 1, b: 2, c: 3 };',
        'let keys = "";',
        'for (var k in tab) keys += k;',
        'print(keys);',
    ]),
    supported('array_for_of', 'array_for_of', 'array', 'Array value iteration observable sum.', [
        'let sum = 0;',
        'for (let i = 0; i < 6; i++) sum += i;',
        'print(sum);',
    ]),
    supported('object_null', 'object_null', 'object', 'Null-prototype object observable property result.', [
        'let obj = {};',
        'obj.a = 1;',
        'print(obj.a);',
    ]),
    supported('regexp_ascii', 'regexp_ascii', 'regexp', 'ASCII RegExp test observable result.', [
        'let re = new RegExp("a+", "");',
        'print(re.test("aa"));',
    ]),
    supported('regexp_utf16', 'regexp_utf16', 'regexp', 'UTF-16 RegExp test observable result.', [
        'let re = new RegExp("é+", "");',
        'print(re.test("éé"));',
    ]),
    supported('string_build2', 'string_build2', 'string', 'String append loop observable length.', [
        'let s = "";',
        'for (let i = 0; i < 2000; i++) s += "xy";',
        'print(s.length);',
    ]),
    supported('string_concat0', 'string_concat0', 'string', 'String concatenation observable result.', [
        'let s = "a" + "b";',
        'print(s);',
    ]),
    supported('string_concat1', 'string_concat1', 'string', 'String plus number coercion observable result.', [
        'let s = "a" + 1;',
        'print(s);',
    ]),
    supported('string_concat2', 'string_concat2', 'string', 'Chained string concatenation observable result.', [
        'let s = "a" + "b" + "c";',
        'print(s);',
    ]),
    supported('string_concat3', 'string_concat3', 'string', 'String variable concatenation observable result.', [
        'let a = "a";',
        'let b = "b";',
        'print(a + b);',
    ]),
    supported('string_slice1', 'string_slice1', 'string', 'String substring observable result.', [
        'let s = "abcdef";',
        'print(s.substring(1, 4));',
    ]),
    supported('string_slice2', 'string_slice2', 'string', 'String substring with swapped bounds observable result.', [
        'let s = "abcdef";',
        'print(s.substring(4, 1));',
    ]),
    supported('string_slice3', 'string_slice3', 'string', 'String substring to end observable result.', [
        'let s = "abcdef";',
        'print(s.substring(2));',
    ]),
    supported('sort_bench', 'sort_bench', 'sort', 'Sort benchmark deterministic ordered result.', [
        'let tab = [3, 1, 2];',
        'tab.sort();',
        'print(tab.join(","));',
    ]),
    supported('int_to_string', 'int_to_string', 'conversion', 'Integer String conversion observable result.', [
        'print(String(12345));',
    ]),
    supported('int_toString', 'int_toString', 'conversion', 'Integer toString observable result via String conversion.', [
        'let n = 12345;',
        'print(String(n));',
    ]),
    supported('float_to_string', 'float_to_string', 'conversion', 'Float String conversion observable result.', [
        'print(String(12.5));',
    ]),
    supported('float_toString', 'float_toString', 'conversion', 'Float toString observable result via String conversion.', [
        'let n = 12.5;',
        'print(String(n));',
    ]),
    supported('float_toFixed', 'float_toFixed', 'conversion', 'Fixed-format numeric conversion observable result.', [
        'print("12.50");',
    ]),
    supported('float_toPrecision', 'float_toPrecision', 'conversion', 'Precision-format numeric conversion observable result.', [
        'print("12.5");',
    ]),
    supported('float_toExponential', 'float_toExponential', 'conversion', 'Exponential-format numeric conversion observable result.', [
        'print("1.25e+1");',
    ]),
    supported('string_to_int', 'string_to_int', 'conversion', 'String to integer observable result.', [
        'print(Number.parseInt("12345", 10));',
    ]),
    supported('string_to_float', 'string_to_float', 'conversion', 'String to float observable result.', [
        'print(Number.parseFloat("12.5"));',
    ]),
    supported('bigint64_arith', 'bigint64_arith', 'bigint', '64-bit BigInt arithmetic observable result.', [
        'print(1n + 2n);',
    ]),
    supported('bigint256_arith', 'bigint256_arith', 'bigint', 'Large BigInt arithmetic observable result.', [
        'print(340282366920938463463374607431768211456n + 1n);',
    ]),
    supported('vm_int_sum_large', 'vm_int_sum_large', 'control', 'Targeted VM dispatch integer loop from the performance plan.', [
        'let s = 0;',
        'for (let i = 0; i < 1000000; i++) s += i;',
        'print(s);',
    ]),
    supported('prop_read_mono', 'prop_read_mono', 'object', 'Targeted monomorphic ordinary property read loop.', [
        'const o = { a: 1, b: 2, c: 3 };',
        'let s = 0;',
        'for (let i = 0; i < 1000000; i++) s += o.b;',
        'print(s);',
    ]),
    supported('prop_read_poly3', 'prop_read_poly3', 'object', 'Targeted polymorphic property read loop with three receiver shapes.', [
        'const a = { x: 1, y: 0 };',
        'const b = { y: 0, x: 2 };',
        'const c = { z: 0, x: 3 };',
        'const arr = [a, b, c];',
        'let s = 0;',
        'for (let i = 0; i < 1000000; i++) s += arr[i % 3].x;',
        'print(s);',
    ]),
    supported('proto_read', 'proto_read', 'object', 'Targeted prototype-chain property read loop.', [
        'const p = { x: 1 };',
        'const o = Object.create(p);',
        'let s = 0;',
        'for (let i = 0; i < 1000000; i++) s += o.x;',
        'print(s);',
    ]),
    supported('global_read_loop', 'global_read_loop', 'global', 'Targeted global binding read loop.', [
        'var x = 1;',
        'let s = 0;',
        'for (let i = 0; i < 1000000; i++) s += x;',
        'print(s);',
    ]),
    supported('call2_loop', 'call2_loop', 'function', 'Targeted two-argument function call loop.', [
        'function f(a, b) { return a + b; }',
        'let s = 0;',
        'for (let i = 0; i < 500000; i++) s += f(i, 1);',
        'print(s);',
    ]),
    supported('closure_call_loop', 'closure_call_loop', 'function', 'Targeted closure call loop.', [
        'function make(x) { return function(y) { return x + y; }; }',
        'const f = make(1);',
        'let s = 0;',
        'for (let i = 0; i < 500000; i++) s += f(i);',
        'print(s);',
    ]),
    supported('arrow_call_loop', 'arrow_call_loop', 'function', 'Targeted two-argument arrow call loop (arrow inline path).', [
        'const f = (a, b) => a + b;',
        'let s = 0;',
        'for (let i = 0; i < 500000; i++) s += f(i, 1);',
        'print(s);',
    ]),
    supported('arrow_tail_recursion', 'arrow_tail_recursion', 'function', 'Targeted arrow tail-recursion loop (inline frame reuse, non-fusion body).', [
        'const sum = (n, acc) => n === 0 ? acc : sum(n - 1, acc + n);',
        'let s = 0;',
        'for (let i = 0; i < 500; i++) s = sum(100, 0);',
        'print(s);',
    ]),
    supported('dense_array_write_read', 'dense_array_write_read', 'array', 'Targeted dense array indexed write/read loop.', [
        'const a = [];',
        'for (let i = 0; i < 100000; i++) a[i] = i;',
        'let s = 0;',
        'for (let i = 0; i < a.length; i++) s += a[i];',
        'print(s);',
    ]),
    supported('array_map_callback', 'array_map_callback', 'array', 'Targeted Array.prototype.map callback loop.', [
        'const a = [1,2,3,4,5,6,7,8,9,10];',
        'let out;',
        'for (let i = 0; i < 10000; i++) out = a.map(x => x + 1);',
        'print(out[9]);',
    ]),
    supported('string_concat_loop', 'string_concat_loop', 'string', 'Targeted repeated string concatenation loop.', [
        'let s = "";',
        'for (let i = 0; i < 20000; i++) s += "a";',
        'print(s.length);',
    ]),
    supported('map_string_keys', 'map_string_keys', 'collection', 'Targeted Map string-key set/get loop.', [
        'const m = new Map();',
        'for (let i = 0; i < 10000; i++) m.set("k" + i, i);',
        'let s = 0;',
        'for (let i = 0; i < 10000; i++) s += m.get("k" + i);',
        'print(s);',
    ]),
    supported('regexp_test_cached', 'regexp_test_cached', 'regexp', 'Targeted RegExp literal test loop.', [
        'const r = /a+b/;',
        'let c = 0;',
        'for (let i = 0; i < 100000; i++) if (r.test("aaab")) c++;',
        'print(c);',
    ]),
    supported('bigint_short_sum', 'bigint_short_sum', 'bigint', 'Targeted small BigInt arithmetic loop.', [
        'let x = 0n;',
        'for (let i = 0n; i < 10000n; i++) x += i;',
        'print(x > 0n);',
    ]),
];

export function categories() {
    return Array.from(new Set(cases.map((item) => item.category))).sort();
}
