// Ordinary-call fixed-cost probe, not a policy sentinel (see README). Four exact
// arguments with only the first consumed, so the delta against call_identity_1
// is argument passing alone and not additional callee work.
function run() {
    function f(a, b, c, d) {
        return a;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f(1, 2, 3, 4);
    return s;
}
