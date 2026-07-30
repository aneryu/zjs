// P6-03c JS-level BigInt allocation-boundary probe, not a policy sentinel (see
// README). Shapes are ordered: lhs has 28 limbs of 64 bits, rhs has 28, so the
// product's flexible array member is 56 limbs. That is the allocator boundary
// P6-03b pinned: a 56-byte wrapper plus 56 limbs is 504 bytes of payload, and
// the slab's ceiling is 504. Both operands are built once at module scope so the
// retained run() times only the multiplication, and each iteration overwrites r
// so the operand size never grows. String(r) is used instead of the CLI
// inspector so the checksum is identical across engines.
const a = (1n << 28n * 64n - 1n) | 1n;
const b = (1n << 28n * 64n - 1n) | 1n;
function run() {
    let r = 0n;
    for (let i = 0; i < 2000; i++) r = a * b;
    return String(r).length;
}
