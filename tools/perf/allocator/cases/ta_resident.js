// Identical transient traffic to ta_churn.js, but a retained population of the
// same size leaves a partially-filled arena on the class free list, so the
// transient allocation reuses a block instead of creating an arena. The count is
// deliberately not a multiple of the blocks-per-arena figure: a population that
// exactly fills its arenas leaves the free list empty and churns anyway.
const keep = [];
for (let i = 0; i < 411; i++) keep.push(new Uint8Array(64));
let sink = 0;
for (let i = 0; i < 200000; i++) {
    const b = new Uint8Array(64);
    b[0] = i & 255;
    sink += b[0];
}
sink += keep[410][0];
print(sink);
