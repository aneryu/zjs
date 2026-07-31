let sink = 0;
for (let i = 0; i < 2000; i++) {
    const b = new Uint8Array(256);
    b[0] = i & 255;
    sink += b[0];
}
print(sink);
