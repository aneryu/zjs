// P6-02 JS-level BigInt allocation topology probe, not a policy sentinel (see
// README). Shapes are ordered: lhs has 1 limbs of 64 bits, rhs has 8. Both
// operands are built once at module scope so the retained run() times only the
// multiplication, and each iteration overwrites r so the operand size never
// grows. String(r) is used instead of the CLI inspector so the checksum is
// identical across engines.
const a = (1n << 1n * 64n - 1n) | 1n;
const b = (1n << 8n * 64n - 1n) | 1n;
function run() {
    let r = 0n;
    for (let i = 0; i < 20000; i++) r = a * b;
    return String(r).length;
}
