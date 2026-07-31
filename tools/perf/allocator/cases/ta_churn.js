// Transient 64-byte typed array per iteration, nothing retained: the 80-byte
// size class empties on every free, so each iteration pays an arena
// acquire/release pair.
let sink = 0;
for (let i = 0; i < 200000; i++) {
    const b = new Uint8Array(64);
    b[0] = i & 255;
    sink += b[0];
}
print(sink);
