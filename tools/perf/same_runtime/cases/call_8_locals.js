// Ordinary-call fixed-cost probe, not a policy sentinel (see README). Eight live
// locals so the frame is materially larger than the identity cases; the delta
// against call_identity_1 is what per-call frame geometry and slot
// initialization cost. Every intermediate stays in int32 range.
function run() {
    function f(a) {
        const l0 = a;
        const l1 = a + 1;
        const l2 = a + 2;
        const l3 = a + 3;
        const l4 = a + 4;
        const l5 = a + 5;
        const l6 = a + 6;
        const l7 = a + 7;
        return (l0 ^ l1 ^ l2 ^ l3 ^ l4 ^ l5 ^ l6 ^ l7) & 0xff;
    }
    let s = 0;
    for (let i = 0; i < 300000; i++) s += f(i & 0xff);
    return s;
}
