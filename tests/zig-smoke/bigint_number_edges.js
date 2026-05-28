var maxMagnitude = 0n;
for (var i = 971n; i < 1024n; i++) {
  maxMagnitude += 2n ** i;
}

print(BigInt(Number.MAX_VALUE) === maxMagnitude);
print(Number(maxMagnitude + (2n ** 970n - 1n)) === Number.MAX_VALUE);
print(Number(maxMagnitude + 2n ** 970n));

var wideBits = 2 ** 32;
print(BigInt.asIntN(wideBits, 1n));
print(BigInt.asIntN(wideBits, 0n));
print(BigInt.asIntN(wideBits, -1n));
print(BigInt.asUintN(Number.MAX_SAFE_INTEGER, 1n));
print(BigInt.asUintN(Number.MAX_SAFE_INTEGER, 0n));
