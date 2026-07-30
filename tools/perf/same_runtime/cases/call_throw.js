// Ordinary-call semantic-shape probe, not a policy sentinel (see README). Every
// iteration throws across one call boundary and catches, exercising abrupt
// completion, frame teardown and backtrace capture. The iteration count is far
// lower than the other call cases because error construction dominates it.
function run() {
    function f(n) {
        throw n;
    }
    let s = 0;
    for (let i = 0; i < 20000; i++) {
        try {
            f(1);
        } catch (e) {
            s += e;
        }
    }
    return s;
}
