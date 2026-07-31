// P7-70 amplified diagnostics.
//
// Five cases derived from the 75-case suite's *startup-dominated* entries. Each
// source case is one where the whole-process measurement cannot resolve any
// execution signal (startup share 88-92%) and where no same-runtime control
// exists in tools/perf/same_runtime/cases, so the mechanism is currently
// unmeasured at every layer.
//
// These are DIAGNOSTIC ONLY:
//   - new names and new source SHA-256, so they can never be confused with the
//     historical 75;
//   - they do not replace any historical case and the historical sources and
//     iteration counts are untouched;
//   - they are never part of the compatibility geomean.
//
// Sizing target: qjs workload execution time >= 5x the currently measured qjs
// startup baseline (0.431 ms at 042e4962, CPU 19), i.e. >= ~2.2 ms of execution.
// Every case prints a deterministic checksum so the stdout comparison still
// validates the workload rather than just its exit code.

const amplified = (name, sourceCase, category, subsystemGap, source) => ({
    name,
    quickjsName: `${sourceCase} (P7-70 amplified)`,
    category,
    expectedStatus: 'supported',
    notes: `Amplified from the startup-dominated case ${sourceCase}; ${subsystemGap}. Diagnostic only: not part of the 75-case compatibility geomean.`,
    diagnosticOnly: true,
    derivedFrom: sourceCase,
    source: source.join('\n'),
});

export const cases = [
    amplified(
        'amp_date_now',
        'date_now',
        'date',
        'the date subsystem has exactly one case in the suite and no same-runtime control',
        [
            'let sink = 0;',
            'let monotonic = 1;',
            'for (let i = 0; i < 400000; i++) {',
            '    const now = Date.now();',
            '    if (now <= 0) monotonic = 0;',
            '    sink += now % 7;',
            '}',
            'print(monotonic);',
            'print(sink > 0);',
        ],
    ),
    amplified(
        'amp_json_roundtrip',
        'json_roundtrip',
        'json',
        'JSON parse/stringify has no same-runtime control and its only suite case is 88.7% startup',
        [
            'const seed = { a: 1, b: [2, 3], c: { d: "text", e: [4, 5, 6] }, f: true, g: null };',
            'let checksum = 0;',
            'for (let i = 0; i < 20000; i++) {',
            '    const text = JSON.stringify(seed);',
            '    const obj = JSON.parse(text);',
            '    checksum += obj.a + obj.b[1] + obj.c.e[2] + text.length;',
            '}',
            'print(checksum);',
        ],
    ),
    amplified(
        'amp_sort_bench',
        'sort_bench',
        'sort',
        'Array.prototype.sort has no same-runtime control and its only suite case sorts three elements',
        [
            'let checksum = 0;',
            'for (let round = 0; round < 2000; round++) {',
            '    const tab = [];',
            '    let x = round + 1;',
            '    for (let i = 0; i < 64; i++) {',
            '        x = (x * 1103515245 + 12345) % 2147483647;',
            '        tab.push(x % 1000);',
            '    }',
            '    tab.sort();',
            '    checksum += tab[0] + tab[63];',
            '}',
            'print(checksum);',
        ],
    ),
    amplified(
        'amp_string_slice3',
        'string_slice3',
        'string',
        'string slicing has no same-runtime control and its three suite cases are 91-92% startup',
        [
            'const base = "abcdefghijklmnopqrstuvwxyz0123456789";',
            'let checksum = 0;',
            'for (let i = 0; i < 200000; i++) {',
            '    const start = i % 30;',
            '    const part = base.substring(start);',
            '    checksum += part.length + part.charCodeAt(0);',
            '}',
            'print(checksum);',
        ],
    ),
    amplified(
        'amp_map_set',
        'map_set',
        'collection',
        'the Map/WeakMap family is five suite cases, all startup-dominated, with no same-runtime control',
        [
            'let checksum = 0;',
            'for (let round = 0; round < 400; round++) {',
            '    const map = new Map();',
            '    for (let i = 0; i < 500; i++) map.set(i, i + round);',
            '    for (let i = 0; i < 500; i++) checksum += map.get(i);',
            '    checksum += map.size;',
            '}',
            'print(checksum);',
        ],
    ),
];

export const categories = () => [...new Set(cases.map((item) => item.category))].sort();
