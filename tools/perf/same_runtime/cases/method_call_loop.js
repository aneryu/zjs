// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// its top-level receiver/accumulator become function-local state per run().
function run() {
    const o = {
        v: 7,
        m(x) {
            let r = this.v + x;
            if (r > 1000000000) r = 0;
            return r;
        },
    };
    let s = 0;
    for (let i = 0; i < 300000; i++) s += o.m(i);
    return s;
}
