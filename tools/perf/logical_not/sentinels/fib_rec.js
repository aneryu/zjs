// P7-61 collateral sentinel wrapper: the checked-in same-runtime case
// `tools/perf/same_runtime/cases/fib_rec.js` verbatim, driven 120 times.
// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// its top-level fib declaration becomes an inner closure recreated per run().
function run() {
    function fib(n) {
        if (n < 2) return n;
        const a = fib(n - 1);
        const b = fib(n - 2);
        return a + b;
    }
    return fib(24);
}

var acc = 0;
for (var rep = 0; rep < 120; rep++) acc += run();
print(acc);
