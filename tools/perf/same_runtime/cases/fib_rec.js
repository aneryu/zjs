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
