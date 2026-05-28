// C parity: standard globals registered by C QuickJS should exist.
print(typeof Math);
print(typeof JSON);
print(typeof Promise);
print(typeof Map);
print(typeof Set);
print(typeof ArrayBuffer);
print(typeof DataView);
print(typeof Symbol);
print(typeof gc);
print(gc.length);
print(gc());
print(typeof navigator);
print(navigator.userAgent);
print(Object.prototype.toString.call(navigator));
