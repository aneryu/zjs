// Provenance: distinct from tools/compare/microbench_cases.js typed_array_read;
// this same-runtime workload performs initialization plus 250,000 indexed reads.
function run() {
    const t = new Int32Array(1024);
    for (let i = 0; i < 1024; i++) t[i] = i;
    let s = 0;
    for (let i = 0; i < 250000; i++) s += t[i & 1023];
    return s;
}
print(run());
