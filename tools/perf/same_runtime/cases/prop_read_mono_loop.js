// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// its top-level lexical object/accumulator become function-local per run().
function run() {
    const o = { a: 1, b: 2, c: 3 };
    let s = 0;
    for (let i = 0; i < 1000000; i++) s += o.a;
    return s;
}
