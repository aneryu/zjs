// P6-04a JS-level BigInt division baseline, not a policy sentinel (see
// README). Shapes are ordered: the numerator has 8 limbs of 64 bits and the
// divisor 4. The numerator's top limb is saturated so the numerator is
// strictly larger and the case measures the division itself rather than the
// `numerator < divisor` early return. Both operands are built once at module
// scope, each iteration overwrites r, and the checksum is String(r).length so
// it is identical across engines.
//
// The iteration count is 200 rather than the multiplication cases' 20000
// because the current implementation walks the numerator one bit at a time and
// a single division costs microseconds.
const a = ((1n << 8n * 64n) - 1n);
const b = (1n << 4n * 64n - 1n) | 3n;
function run() {
    let r = 0n;
    for (let i = 0; i < 200; i++) r = a / b;
    return String(r).length;
}
