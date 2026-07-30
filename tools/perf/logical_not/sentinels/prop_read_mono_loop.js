// P7-61 collateral sentinel wrapper: the checked-in same-runtime case
// `tools/perf/same_runtime/cases/prop_read_mono_loop.js` verbatim, driven 120 times.
// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// its top-level lexical object/accumulator become function-local per run().
function run() {
    const o = { a: 1, b: 2, c: 3 };
    let s = 0;
    for (let i = 0; i < 1000000; i++) s += o.a;
    return s;
}

var acc = 0;
for (var rep = 0; rep < 120; rep++) acc += run();
print(acc);
