// Ordinary-call fixed-cost probe, not a policy sentinel (see README). Zero
// arguments and the smallest body that still yields a checksummable result, so
// what the loop measures is call admission, frame setup and return rather than
// callee work. The accumulator stays inside int32 for 300,000 iterations.
function run() {
    function f() {
        return 1;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f();
    return s;
}
