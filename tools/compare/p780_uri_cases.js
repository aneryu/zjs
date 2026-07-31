// P7-80 URI decode attribution corpus.
//
// The headline cases `uri_decode_4byte` / `uri_component_decode_4byte` are
// NOT pure decode workloads: each of their 16 * 64 * 64 = 65536 inner
// iterations also does string indexing, three `+` concatenations, a
// `String.fromCharCode` call and a string equality. This corpus decomposes
// that workload into an additive ladder plus per-call decode controls so the
// string-building half and the decode half can be separated before any
// decode-internal attribution is attempted.
//
// These are DIAGNOSTIC ONLY:
//   - new names, and every rung prints a deterministic checksum so the stdout
//     comparison still validates the workload rather than just the exit code;
//   - they never enter the 75-case compatibility geomean;
//   - `p780_L3_full` / `p780_L3c_full` carry the historical sources verbatim,
//     so their `sourceSha256` matches `uri_decode_4byte` /
//     `uri_component_decode_4byte` and the ladder's top rung is provably the
//     same workload as the P7-70 headline.
//
// Every rung keeps the historical loop nest (16 * 64 * 64) and the historical
// top-level `var` scoping, so rung-to-rung differences are attributable to the
// statement that was added, not to a scoping or trip-count change.

const p780 = (name, stage, notes, source) => ({
    name,
    quickjsName: `P7-80 ${stage}`,
    category: 'uri',
    expectedStatus: 'supported',
    notes: `${notes} Diagnostic only: not part of the 75-case compatibility geomean.`,
    diagnosticOnly: true,
    derivedFrom: 'uri_decode_4byte',
    source: source.join('\n'),
});

// Shared prologue/epilogue fragments for the additive ladder. The index/L/H
// arithmetic is present on every rung including the skeleton, so it never
// appears in a rung-to-rung difference.
const NEST_OPEN = [
    'var count = 0;',
    'for (var repeat = 0; repeat < 16; repeat++) {',
    '  for (var indexB3 = 0x80; indexB3 <= 0xBF; indexB3++) {',
];
const NEST_MID = [
    '    for (var indexB4 = 0x80; indexB4 <= 0xBF; indexB4++) {',
    '      var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);',
    '      var L = ((index - 0x10000) & 0x03FF) + 0xDC00;',
    '      var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;',
];
const NEST_CLOSE = [
    '    }',
    '  }',
    '}',
    'print(count);',
];

const HEX_FN = [
    'function decimalToPercentHexString(n) {',
    '  var hex = "0123456789ABCDEF";',
    '  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];',
    '}',
];

// The two historical sources, verbatim.
const HISTORICAL = (fn) => [
    ...HEX_FN,
    'var count = 0;',
    'for (var repeat = 0; repeat < 16; repeat++) {',
    '  for (var indexB3 = 0x80; indexB3 <= 0xBF; indexB3++) {',
    '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
    '    for (var indexB4 = 0x80; indexB4 <= 0xBF; indexB4++) {',
    '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
    '      var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);',
    '      var L = ((index - 0x10000) & 0x03FF) + 0xDC00;',
    '      var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;',
    `      if (${fn}(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;`,
    '    }',
    '  }',
    '}',
    'print(count);',
];

// Per-call decode controls: 65536 calls, the same call count as one full
// ladder run, on a hoisted argument so no per-iteration string building can
// leak into the measurement.
const decodeControl = (name, literal, notes, fn = 'decodeURI') =>
    p780(name, `decode control ${name}`, notes, [
        `var s = ${JSON.stringify(literal)};`,
        'var count = 0;',
        `for (var i = 0; i < 65536; i++) count += ${fn}(s).length;`,
        'print(count);',
    ]);

const ESC1 = '%F0%A0%80%80';

export const cases = [
    // ---------------------------------------------------------------- ladder
    p780(
        'p780_L0_skeleton',
        'L0 skeleton',
        'Loop nest and integer arithmetic only; no string is created. Floor for every other rung.',
        [...NEST_OPEN, ...NEST_MID, '      count += (H ^ L) & 1;', ...NEST_CLOSE],
    ),
    p780(
        'p780_L1_build',
        'L1 skeleton + string building',
        'Adds the helper call, two string index reads and three concatenations; the built string is consumed by .length only. L1 - L0 is the string-building half.',
        [
            ...HEX_FN,
            ...NEST_OPEN,
            '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
            ...NEST_MID,
            '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
            '      count += hexB1_B2_B3_B4.length & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_L1f_build_flat',
        'L1f skeleton + string building, result forced flat',
        'Same as L1 but consumes the built string with charCodeAt(11), which forces a rope-backed result to flatten. L1f - L1 isolates any deferred flatten cost.',
        [
            ...HEX_FN,
            ...NEST_OPEN,
            '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
            ...NEST_MID,
            '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
            '      count += hexB1_B2_B3_B4.charCodeAt(11) & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_L2_decode',
        'L2 skeleton + building + decodeURI',
        'Adds decodeURI over the built 12-byte string, consumed by .length. L2 - L1 is the decode half in isolation.',
        [
            ...HEX_FN,
            ...NEST_OPEN,
            '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
            ...NEST_MID,
            '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
            '      count += decodeURI(hexB1_B2_B3_B4).length & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_L2s_fromcharcode',
        'L2s skeleton + building + String.fromCharCode',
        'Adds String.fromCharCode(H, L) instead of decodeURI, consumed by .length. L2s - L1 is the fromCharCode half in isolation.',
        [
            ...HEX_FN,
            ...NEST_OPEN,
            '    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);',
            ...NEST_MID,
            '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);',
            '      count += (hexB1_B2_B3_B4.length + String.fromCharCode(H, L).length) & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_L3_full',
        'L3 full (uri_decode_4byte verbatim)',
        'The historical uri_decode_4byte source verbatim; its sourceSha256 must equal the historical case.',
        HISTORICAL('decodeURI'),
    ),
    p780(
        'p780_L3c_full',
        'L3c full component (uri_component_decode_4byte verbatim)',
        'The historical uri_component_decode_4byte source verbatim.',
        HISTORICAL('decodeURIComponent'),
    ),

    // ------------------------------------------------- building sub-ladder
    p780(
        'p780_B0_call',
        'B0 helper call only',
        'The helper is called twice per middle-loop trip and once per inner trip but returns a hoisted constant: isolates call plus constant-string materialization from indexing and concatenation.',
        [
            'function constHex(n) {',
            '  var hex = "0123456789ABCDEF";',
            '  return hex;',
            '}',
            ...NEST_OPEN,
            ...NEST_MID,
            '      count += constHex(indexB4).length & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_B1_index',
        'B1 helper call + two string index reads',
        'B1 - B0 is the cost of the two single-character string index reads per inner iteration.',
        [
            'function twoIndex(n) {',
            '  var hex = "0123456789ABCDEF";',
            '  return hex[(n >> 4) & 0xf].length + hex[n & 0xf].length;',
            '}',
            ...NEST_OPEN,
            ...NEST_MID,
            '      count += twoIndex(indexB4) & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_B2_hexconcat',
        'B2 helper call + index reads + two short concatenations',
        'The full decimalToPercentHexString, consumed by .length. B2 - B1 is the two short concatenations that build "%XX".',
        [
            ...HEX_FN,
            ...NEST_OPEN,
            ...NEST_MID,
            '      count += decimalToPercentHexString(indexB4).length & 1;',
            ...NEST_CLOSE,
        ],
    ),
    p780(
        'p780_B3_outerconcat',
        'B3 the 9 + 3 outer concatenation only',
        'Concatenates a hoisted 9-character string with a hoisted 3-character string. Isolates the 12-character result allocation from everything upstream.',
        [
            ...NEST_OPEN,
            '    var hexB1_B2_B3 = "%F0%A0%80";',
            ...NEST_MID,
            '      var hexB1_B2_B3_B4 = hexB1_B2_B3 + "%80";',
            '      count += hexB1_B2_B3_B4.length & 1;',
            ...NEST_CLOSE,
        ],
    ),

    // ------------------------------------------------------- decode-only
    p780(
        'p780_L4_decode_only',
        'L4 decode + fromCharCode + equality over precomputed inputs',
        'Precomputes the 4096 distinct inputs and their expected results once, then runs the historical 65536 decode/fromCharCode/equality triples with zero per-iteration string building.',
        [
            ...HEX_FN,
            'var inputs = [];',
            'var highs = [];',
            'var lows = [];',
            'for (var b3 = 0x80; b3 <= 0xBF; b3++) {',
            '  var pre = "%F0%A0" + decimalToPercentHexString(b3);',
            '  for (var b4 = 0x80; b4 <= 0xBF; b4++) {',
            '    inputs.push(pre + decimalToPercentHexString(b4));',
            '    var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (b3 & 0x3F) * 0x40 + (b4 & 0x3F);',
            '    lows.push(((index - 0x10000) & 0x03FF) + 0xDC00);',
            '    highs.push((((index - 0x10000) >> 10) & 0x03FF) + 0xD800);',
            '  }',
            '}',
            'var count = 0;',
            'for (var repeat = 0; repeat < 16; repeat++) {',
            '  for (var j = 0; j < 4096; j++) {',
            '    if (decodeURI(inputs[j]) === String.fromCharCode(highs[j], lows[j])) count++;',
            '  }',
            '}',
            'print(count);',
        ],
    ),
    p780(
        'p780_L4b_arrays_only',
        'L4b array-read floor for L4',
        'The L4 setup and loop nest with the decode/fromCharCode/equality triple replaced by the three array reads it needs. L4 - L4b is decode + fromCharCode + equality with no string building at all.',
        [
            ...HEX_FN,
            'var inputs = [];',
            'var highs = [];',
            'var lows = [];',
            'for (var b3 = 0x80; b3 <= 0xBF; b3++) {',
            '  var pre = "%F0%A0" + decimalToPercentHexString(b3);',
            '  for (var b4 = 0x80; b4 <= 0xBF; b4++) {',
            '    inputs.push(pre + decimalToPercentHexString(b4));',
            '    var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (b3 & 0x3F) * 0x40 + (b4 & 0x3F);',
            '    lows.push(((index - 0x10000) & 0x03FF) + 0xDC00);',
            '    highs.push((((index - 0x10000) >> 10) & 0x03FF) + 0xD800);',
            '  }',
            '}',
            'var count = 0;',
            'for (var repeat = 0; repeat < 16; repeat++) {',
            '  for (var j = 0; j < 4096; j++) {',
            '    if (inputs[j].length + highs[j] + lows[j] > 0) count++;',
            '  }',
            '}',
            'print(count);',
        ],
    ),

    // --------------------------------------------------- decode controls
    p780(
        'p780_dec_base',
        'decode control floor',
        '65536 trips reading .length of a hoisted 12-byte string; the floor every decode control is measured against.',
        [
            `var s = ${JSON.stringify(ESC1)};`,
            'var count = 0;',
            'for (var i = 0; i < 65536; i++) count += s.length;',
            'print(count);',
        ],
    ),
    decodeControl(
        'p780_dec_plain12',
        'abcdefghijkl',
        '12 input bytes, no percent escape, 12 output characters: scan-dominated, no escape decoding.',
    ),
    decodeControl(
        'p780_dec_ascii1',
        '%41',
        '3 input bytes, one ASCII escape, 1 output character.',
    ),
    decodeControl(
        'p780_dec_ascii4',
        '%41%42%43%44',
        '12 input bytes, four ASCII escapes, 4 narrow output characters.',
    ),
    decodeControl(
        'p780_dec_ascii16',
        '%41%42%43%44%45%46%47%48%49%4A%4B%4C%4D%4E%4F%50',
        '48 input bytes, sixteen ASCII escapes, 16 narrow output characters.',
    ),
    decodeControl(
        'p780_dec_esc1',
        ESC1,
        '12 input bytes, one four-byte UTF-8 escape, 2 wide output units. This is the exact input shape of the historical case.',
    ),
    decodeControl(
        'p780_dec_esc2',
        `${ESC1}%F0%A0%80%81`,
        '24 input bytes, two four-byte escapes, 4 wide output units.',
    ),
    decodeControl(
        'p780_dec_esc4',
        `${ESC1}%F0%A0%80%81%F0%A0%80%82%F0%A0%80%83`,
        '48 input bytes, four four-byte escapes, 8 wide output units.',
    ),
    decodeControl(
        'p780_dec_esc8',
        `${ESC1}%F0%A0%80%81%F0%A0%80%82%F0%A0%80%83%F0%A0%80%84%F0%A0%80%85%F0%A0%80%86%F0%A0%80%87`,
        '96 input bytes, eight four-byte escapes, 16 wide output units.',
    ),
    decodeControl(
        'p780_deccomp_esc1',
        ESC1,
        'decodeURIComponent counterpart of p780_dec_esc1.',
        'decodeURIComponent',
    ),
];

export const categories = () => [...new Set(cases.map((item) => item.category))].sort();
