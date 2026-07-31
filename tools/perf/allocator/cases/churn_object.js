// Churn shape: one short-lived object per iteration, nothing retained, so the
// object's size class oscillates across the empty boundary and every iteration
// can force an arena acquire/release pair.
let sink = 0;
for (let i = 0; i < 200000; i++) {
    const o = { a: i, b: i + 1 };
    sink += o.a + o.b;
}
print(sink);
