// Attribution sentinel, deliberately NOT a policy sentinel: it exists to detect
// dispatch-wide collateral from a single opcode's hot/cold reclassification, and
// adding it to policy.json would silently change the P0 exit-line geomean.
// Purely local arithmetic and loop dispatch -- no global write, no property
// access, no call -- and every intermediate is masked back into int32 range so a
// float-overflow confound cannot creep in over 300,000 iterations.
function run() {
    let a = 0;
    let b = 1;
    for (let i = 0; i < 300000; i++) {
        a = (a + i) & 0xffff;
        b = (b ^ a) & 0xffff;
        a = (a - (b & 255)) & 0xffff;
    }
    return a + b;
}
