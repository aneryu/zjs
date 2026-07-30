// Ordinary-call semantic-shape probe, not a policy sentinel (see README). Reading
// `arguments` forces the mapped-arguments path, so this is the sentinel for
// changes that make the plain frame cheaper by deferring argument bookkeeping.
function run() {
    function f(a, b) {
        return arguments.length + a + b;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f(1, 2);
    return s;
}
