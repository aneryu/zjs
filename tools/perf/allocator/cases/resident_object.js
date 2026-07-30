// No-churn control: identical per-iteration allocation and free traffic, but a
// resident population of the same shape keeps at least one arena of that size
// class non-empty, so the empty-arena release arm should never be reached.
const keep = [];
for (let i = 0; i < 400; i++) keep.push({ a: i, b: i + 1 });
let sink = 0;
for (let i = 0; i < 200000; i++) {
    const o = { a: i, b: i + 1 };
    sink += o.a + o.b;
}
sink += keep[399].a;
print(sink);
