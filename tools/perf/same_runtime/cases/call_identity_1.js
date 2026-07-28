// Ordinary-call fixed-cost probe, not a policy sentinel (see README). One exact
// argument returned unchanged: the delta against call_empty_0 isolates what a
// single argument costs to pass and bind, with the callee body held constant.
function run() {
    function f(a) {
        return a;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f(1);
    return s;
}
