// P7-61 collateral sentinel wrapper: the checked-in same-runtime case
// `tools/perf/same_runtime/cases/call_body_loop.js` verbatim, driven 120 times.
// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// top-level f/accumulator become a function-local inner closure and local state.
function run() {
    function f(a, b) {
        let t = a + b;
        t = t * 2;
        if (t < 0) t = -t;
        return t - b;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f(i, 3);
    return s;
}

var acc = 0;
for (var rep = 0; rep < 120; rep++) acc += run();
print(acc);
