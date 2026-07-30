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
