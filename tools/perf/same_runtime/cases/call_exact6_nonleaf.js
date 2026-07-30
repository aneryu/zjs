// Phase 3 ordinary-call probe, not a policy sentinel (see README). The single
// local is load-bearing: without it this callee is leaf-eligible and argc<=3
// takes the exact-args leaf arm instead of the ordinary frame constructor, which
// would mix two mechanisms into the argc 3-to-4 comparison. With it, every arity
// runs the same pushExactSimpleFrameImpl and the only thing that varies across
// the step is whether that body is inlined or reached through its noinline
// wrapper.
function run() {
    function f(a1,a2,a3,a4,a5,a6) {
        const t = a1 + 1;
        return t - 1;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f(1,2,3,4,5,6);
    return s;
}
