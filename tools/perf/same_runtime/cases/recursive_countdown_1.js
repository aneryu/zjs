// Phase 3 ordinary-call probe, not a policy sentinel (see README). Sits between
// call_identity_1 and fib_rec: it keeps recursive frame push/pop and caller
// restore, but each level makes one recursive call instead of two, so a cost
// that shows up here and not in call_identity_1 belongs to recursion rather
// than to call setup, and one that shows up only in fib_rec belongs to the
// second call rather than to the call frame. The returned sum is a real
// checksum, and 600 * 250 stays well inside int32.
function run() {
    function down(n) {
        if (n < 1) return 0;
        return down(n - 1) + 1;
    }
    let s = 0;
    for (let i = 0; i < 600; i++) s += down(250);
    return s;
}
