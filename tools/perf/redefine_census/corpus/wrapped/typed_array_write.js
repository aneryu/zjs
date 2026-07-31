// Provenance: distinct from tools/compare/microbench_cases.js typed_array_write;
// this same-runtime workload performs 250,000 writes plus a checksum pass.
function run() {
    const t = new Int32Array(1024);
    for (let i = 0; i < 250000; i++) t[i & 1023] = i;
    let s = 0;
    for (let i = 0; i < 1024; i++) s += t[i];
    return s;
}
print(run());
