const supported = (name, quickjsName, category, notes, source) => ({
    name,
    quickjsName,
    category,
    expectedStatus: 'supported',
    notes,
    source: source.join('\n'),
});

const unsupported = (name, quickjsName, category, notes) => ({
    name,
    quickjsName,
    category,
    expectedStatus: 'unsupported',
    notes,
});

const argumentCounts = [0, 1, 2, 8, 9, 16, 64];
const callForms = ['direct', 'call', 'apply', 'reflect_apply', 'spread'];

function argumentList(argc) {
    return Array.from({ length: argc }, (_, index) => String(index + 1));
}

function callWork(form, argc) {
    if (form === 'spread') {
        if (argc === 0) return 1200000;
        if (argc <= 2) return 800000;
        if (argc === 8) return 500000;
        if (argc === 9) return 450000;
        if (argc <= 16) return 350000;
        return 125000;
    }
    if (argc === 0) {
        if (form === 'apply') return 3000000;
        if (form === 'reflect_apply') return 2000000;
        return 4000000;
    }
    if (form === 'reflect_apply' && argc === 1) return 1400000;
    if (form === 'reflect_apply' && argc === 2) return 1300000;
    if (form === 'apply' && argc === 2) return 1600000;
    if (form === 'reflect_apply' && argc === 64) return 280000;
    if (argc <= 2) return 1800000;
    if (argc <= 9) return 900000;
    if (argc <= 16) return 600000;
    return 300000;
}

function callExpression(form, args) {
    const joined = args.join(', ');
    switch (form) {
        case 'direct':
            return `callback(${joined})`;
        case 'call':
            return `callback.call(null${joined.length === 0 ? '' : `, ${joined}`})`;
        case 'apply':
            return 'callback.apply(null, values)';
        case 'reflect_apply':
            return 'Reflect.apply(callback, null, values)';
        case 'spread':
            return 'callback(...values)';
        default:
            throw new Error(`unknown call form: ${form}`);
    }
}

function makeCallCase(form, argc) {
    const args = argumentList(argc);
    const iterations = callWork(form, argc);
    const category = callFormCategory(form);
    return supported(
        `${form}_argc${argc}`,
        `${form} argc=${argc}`,
        category,
        `${form} call of a normal bytecode target with ${argc} argument(s).`,
        [
            'function callback() {',
            '    var result = arguments.length + 1;',
            '    if (arguments.length !== 0) {',
            '        result += arguments[0];',
            '        result += arguments[arguments.length - 1];',
            '    }',
            '    return result;',
            '}',
            `var values = [${args.join(', ')}];`,
            'var checksum = 0;',
            `for (var index = 0; index < ${iterations}; index += 1) {`,
            `    checksum += ${callExpression(form, args)};`,
            '}',
            'print(checksum);',
        ],
    );
}

function callFormCategory(form) {
    if (form === 'direct' || form === 'call') return 'call-control';
    if (form === 'spread') return 'spread';
    return 'apply';
}

const callFormCases = callForms.flatMap((form) =>
    argumentCounts.map((argc) => makeCallCase(form, argc)));

export const cases = [
    ...callFormCases,

    supported('apply_null_list', 'Function.apply null argument list', 'arg-shape', 'Null is the zero-length apply argument list.', [
        'function callback() { return arguments.length + 1; }',
        'var checksum = 0;',
        'for (var index = 0; index < 2300000; index += 1) {',
        '    checksum += callback.apply(null, null);',
        '}',
        'print(checksum);',
    ]),
    supported('apply_undefined_list', 'Function.apply undefined argument list', 'arg-shape', 'Undefined is the zero-length apply argument list.', [
        'function callback() { return arguments.length + 1; }',
        'var checksum = 0;',
        'for (var index = 0; index < 2300000; index += 1) {',
        '    checksum += callback.apply(null, undefined);',
        '}',
        'print(checksum);',
    ]),
    supported('apply_dense_array', 'Function.apply dense Array', 'arg-shape', 'Fully dense Array argument materialization.', [
        'function callback() { return arguments.length + arguments[0] + arguments[7]; }',
        'var values = [1, 2, 3, 4, 5, 6, 7, 8];',
        'var checksum = 0;',
        'for (var index = 0; index < 900000; index += 1) {',
        '    checksum += callback.apply(null, values);',
        '}',
        'print(checksum);',
    ]),
    supported('apply_holey_array', 'Function.apply holey Array', 'arg-shape', 'Holey Array must observe an indexed prototype property.', [
        'function callback(a, b, c) { return a + b + c; }',
        'var values = [1, , 3];',
        'Array.prototype[1] = 2;',
        'var checksum = 0;',
        'for (var index = 0; index < 1350000; index += 1) {',
        '    checksum += callback.apply(null, values);',
        '}',
        'delete Array.prototype[1];',
        'print(checksum);',
    ]),
    supported('apply_array_like', 'Function.apply generic array-like', 'arg-shape', 'Generic array-like keeps length snapshot and observable indexed Gets.', [
        'function callback(a, b) { return a + b; }',
        'var values = { 0: 1, 1: 2, length: 2 };',
        'var checksum = 0;',
        'for (var index = 0; index < 1400000; index += 1) {',
        '    checksum += callback.apply(null, values);',
        '}',
        'print(checksum);',
    ]),
    supported('apply_proxy_args', 'Function.apply Proxy array-like', 'arg-shape', 'Proxy argument list observes one length Get and ordered indexed Gets.', [
        'function callback(a, b) { return a + b; }',
        'var reads = 0;',
        'var values = new Proxy([1, 2], {',
        '    get: function (target, key, receiver) {',
        '        reads += 1;',
        '        return Reflect.get(target, key, receiver);',
        '    },',
        '});',
        'var checksum = 0;',
        'for (var index = 0; index < 400000; index += 1) {',
        '    checksum += callback.apply(null, values);',
        '}',
        'print(checksum + ":" + reads);',
    ]),

    supported('target_bytecode', 'Reflect.apply bytecode target', 'target-bytecode', 'Eligible same-Realm normal bytecode target.', [
        'function callback(value) {',
        '    var result = value + 1;',
        '    return result;',
        '}',
        'var values = [1];',
        'var checksum = 0;',
        'for (var index = 0; index < 1800000; index += 1) {',
        '    checksum += Reflect.apply(callback, null, values);',
        '}',
        'print(checksum);',
    ]),
    supported('target_native', 'Reflect.apply native target', 'target-control', 'Native target remains on the authoritative native call route.', [
        'var values = [1, 2];',
        'var checksum = 0;',
        'for (var index = 0; index < 4000000; index += 1) {',
        '    checksum += Reflect.apply(Math.max, null, values);',
        '}',
        'print(checksum);',
    ]),
    supported('target_bound', 'Reflect.apply bound target', 'target-control', 'Bound target remains semantically transparent through the authoritative wrapper.', [
        'function callback(left, right) { return left + right; }',
        'var bound = callback.bind(null, 1);',
        'var values = [2];',
        'var checksum = 0;',
        'for (var index = 0; index < 1500000; index += 1) {',
        '    checksum += Reflect.apply(bound, null, values);',
        '}',
        'print(checksum);',
    ]),
    supported('target_proxy', 'Reflect.apply Proxy target', 'target-control', 'Proxy callable target exercises the observable apply trap fallback.', [
        'function callback(value) { return value + 1; }',
        'var proxy = new Proxy(callback, {',
        '    apply: function (target, thisValue, args) {',
        '        return Reflect.apply(target, thisValue, args);',
        '    },',
        '});',
        'var values = [1];',
        'var checksum = 0;',
        'for (var index = 0; index < 650000; index += 1) {',
        '    checksum += Reflect.apply(proxy, null, values);',
        '}',
        'print(checksum);',
    ]),
    unsupported(
        'target_cross_realm',
        'Reflect.apply cross-Realm target',
        'target-control',
        'The qjs/zjs command-line intersection has no Realm-construction API. Run the cross-Realm execution test in src/tests/exec.zig.',
    ),

    supported('array_foreach_bytecode', 'Array.forEach bytecode callback', 'callback-bytecode', 'One-element Array callback with an eligible bytecode target.', [
        'var checksum = 0;',
        'function callback(value) { checksum += value; }',
        'var values = [1];',
        'for (var index = 0; index < 1800000; index += 1) {',
        '    values.forEach(callback);',
        '}',
        'print(checksum);',
    ]),
    supported('array_foreach_native', 'Array.forEach native callback', 'callback-native-control', 'Native callback normalization control for Array.forEach.', [
        'var values = [[]];',
        'var checksum = 0;',
        'for (var index = 0; index < 2000000; index += 1) {',
        '    values.forEach(Array.isArray);',
        '    checksum += 1;',
        '}',
        'print(checksum);',
    ]),
    supported('array_callback_helper', 'Array.forEach callback to helper', 'callback-helper', 'Bytecode callback immediately calls another bytecode helper.', [
        'function helper(value) { return value + 1; }',
        'var checksum = 0;',
        'function callback(value) { checksum += helper(value); }',
        'var values = [1];',
        'for (var index = 0; index < 1200000; index += 1) {',
        '    values.forEach(callback);',
        '}',
        'print(checksum);',
    ]),
    supported('map_foreach_bytecode', 'Map.forEach bytecode callback', 'callback-bytecode', 'One-element Map callback with an eligible bytecode target.', [
        'var checksum = 0;',
        'function callback(value) { checksum += value; }',
        'var values = new Map([["key", 1]]);',
        'for (var index = 0; index < 2000000; index += 1) {',
        '    values.forEach(callback);',
        '}',
        'print(checksum);',
    ]),
    supported('map_foreach_native', 'Map.forEach native callback', 'callback-native-control', 'Native callback normalization control for Map.forEach.', [
        'var values = new Map([["key", []]]);',
        'var checksum = 0;',
        'for (var index = 0; index < 1700000; index += 1) {',
        '    values.forEach(Array.isArray);',
        '    checksum += 1;',
        '}',
        'print(checksum);',
    ]),
    supported('map_callback_helper', 'Map.forEach callback to helper', 'callback-helper', 'Map callback immediately calls another bytecode helper.', [
        'function helper(value) { return value + 1; }',
        'var checksum = 0;',
        'function callback(value) { checksum += helper(value); }',
        'var values = new Map([["key", 1]]);',
        'for (var index = 0; index < 1500000; index += 1) {',
        '    values.forEach(callback);',
        '}',
        'print(checksum);',
    ]),
    supported('json_parse_reviver', 'JSON.parse reviver', 'callback-bytecode', 'JSON.parse reviver callback with a bytecode helper.', [
        'function helper(value) { return value + 1; }',
        'function reviver(key, value) {',
        '    return typeof value === "number" ? helper(value) : value;',
        '}',
        'var input = "{\\"value\\":1}";',
        'var checksum = 0;',
        'for (var index = 0; index < 270000; index += 1) {',
        '    checksum += JSON.parse(input, reviver).value;',
        '}',
        'print(checksum);',
    ]),
    supported('json_stringify_replacer', 'JSON.stringify replacer', 'callback-bytecode', 'JSON.stringify function replacer callback with a bytecode helper.', [
        'function helper(value) { return value + 1; }',
        'function replacer(key, value) {',
        '    return typeof value === "number" ? helper(value) : value;',
        '}',
        'var input = { value: 1 };',
        'var checksum = 0;',
        'for (var index = 0; index < 270000; index += 1) {',
        '    checksum += JSON.stringify(input, replacer).length;',
        '}',
        'print(checksum);',
    ]),
    supported('json_to_json', 'JSON.stringify toJSON', 'callback-bytecode', 'toJSON callback with a bytecode helper.', [
        'function helper(value) { return value + 1; }',
        'var input = {',
        '    value: 1,',
        '    toJSON: function () { return { value: helper(this.value) }; },',
        '};',
        'var checksum = 0;',
        'for (var index = 0; index < 250000; index += 1) {',
        '    checksum += JSON.stringify(input).length;',
        '}',
        'print(checksum);',
    ]),
    supported('promise_executor_bytecode', 'Promise bytecode executor', 'callback-bytecode', 'Synchronous Promise executor with an eligible bytecode target.', [
        'var iterations = 300000;',
        'var checksum = 0;',
        'function helper(value) { return value + 1; }',
        'function executor(resolve) {',
        '    checksum += helper(1);',
        '    resolve(checksum);',
        '}',
        'for (var index = 0; index < iterations; index += 1) {',
        '    new Promise(executor);',
        '}',
        'print(checksum);',
    ]),
    supported('promise_executor_native', 'Promise native executor', 'callback-native-control', 'Native executor normalization control for Promise construction.', [
        'var iterations = 600000;',
        'for (var index = 0; index < iterations; index += 1) {',
        '    new Promise(Array.isArray);',
        '}',
        'print(iterations);',
    ]),
    supported('getter_bytecode', 'ordinary bytecode getter', 'callback-bytecode', 'Ordinary accessor callback used as a property-cohort sentinel.', [
        'var current = 1;',
        'var object = Object.defineProperty({}, "value", {',
        '    get: function () {',
        '        var result = current + 1;',
        '        return result - 1;',
        '    },',
        '});',
        'var checksum = 0;',
        'for (var index = 0; index < 2800000; index += 1) {',
        '    checksum += object.value;',
        '}',
        'print(checksum);',
    ]),
    supported('for_of_array_control', 'Array for-of control', 'hotpath-control', 'Non-target control for ordinary Array iterator acquisition and stepping.', [
        'var values = [1, 2, 3, 4];',
        'var checksum = 0;',
        'for (var round = 0; round < 650000; round += 1) {',
        '    for (var value of values) checksum += value;',
        '}',
        'print(checksum);',
    ]),

    supported('promise_reaction_job', 'Promise reaction job root', 'root-control', 'Promise reactions remain fresh job execution roots; a fixed direct-call calibration keeps both engine runs long enough to measure.', [
        'var iterations = 12000;',
        'var checksum = 0;',
        'var resolved = Promise.resolve(1);',
        'function reaction(value) { checksum += value; }',
        'function calibration() {',
        '    var result = arguments.length + 1;',
        '    if (arguments.length !== 0) {',
        '        result += arguments[0] + arguments[arguments.length - 1];',
        '    }',
        '    return result;',
        '}',
        'var calibrationChecksum = 0;',
        'for (var calibrationIndex = 0; calibrationIndex < 1150000; calibrationIndex += 1) {',
        '    calibrationChecksum += calibration(1);',
        '}',
        'for (var index = 0; index < iterations; index += 1) {',
        '    resolved.then(reaction);',
        '}',
        'Promise.resolve().then(function () { print(checksum + ":" + calibrationChecksum); });',
    ]),
    supported('generator_resume', 'generator resume root', 'root-control', 'Negative control: generator resume keeps its resident-stack execution-root path.', [
        'function* values() {',
        '    var value = yield 1;',
        '    return value + 1;',
        '}',
        'var checksum = 0;',
        'for (var index = 0; index < 400000; index += 1) {',
        '    var iterator = values();',
        '    checksum += iterator.next().value;',
        '    checksum += iterator.next(1).value;',
        '}',
        'print(checksum);',
    ]),
    supported('async_resume', 'async function resume root', 'root-control', 'Await resumptions remain queued execution roots; a fixed direct-call calibration keeps both engine runs long enough to measure.', [
        'var iterations = 10000;',
        'var checksum = 0;',
        'var pending = [];',
        'function calibration() {',
        '    var result = arguments.length + 1;',
        '    if (arguments.length !== 0) {',
        '        result += arguments[0] + arguments[arguments.length - 1];',
        '    }',
        '    return result;',
        '}',
        'var calibrationChecksum = 0;',
        'for (var calibrationIndex = 0; calibrationIndex < 700000; calibrationIndex += 1) {',
        '    calibrationChecksum += calibration(1);',
        '}',
        'async function resume(value) {',
        '    var resumed = await value;',
        '    checksum += resumed;',
        '}',
        'for (var index = 0; index < iterations; index += 1) {',
        '    pending.push(resume(1));',
        '}',
        'Promise.all(pending).then(function () { print(checksum + ":" + calibrationChecksum); });',
    ]),
];

export function categories() {
    return Array.from(new Set(cases.map((item) => item.category))).sort();
}
