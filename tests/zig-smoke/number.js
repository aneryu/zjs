// Test Number built-in
print(Number.parseInt("42"));
print(Number.parseFloat("3.14"));
print(Number.NaN);
print(Number.POSITIVE_INFINITY);
print(Number.NEGATIVE_INFINITY);
print(typeof globalThis);
print(globalThis.globalThis === globalThis);
print(globalThis.Math === Math);
print(parseInt("0x10"));
print(parseInt("0x10", 16));
print(parseInt("0x10", 10));
print(parseInt("-0xF"));
print(parseInt("+0xF"));
print(parseInt("10", 1));
print(parseInt("10", 37));
print(parseInt("12px"));
print(1 / parseInt("-0"));
print(parseFloat("1.5x"));
print(parseFloat("+.5x"));
print(parseFloat("Infinityx"));
print(parseFloat("-Infinityx"));
print(parseFloat("x1"));
print(1 / parseFloat("-0"));
print((1000000000000000128).toFixed(2));
print((1000000000000000128).toFixed(0));
print((3.141592653589793).toFixed(50));
print((123456.78).toPrecision(50));
print(Number.MIN_VALUE.toPrecision(100));
print((-Number.MIN_VALUE).toFixed(0));
print((1e21).toFixed(100));
var exponentialArgSideEffect = 0;
print(Number.POSITIVE_INFINITY.toExponential({ valueOf: function() { exponentialArgSideEffect = 7; return 200; } }));
print(exponentialArgSideEffect);
try { print((1).toFixed(1e100)); } catch (e) { print(e.name); }
try { print((1).toPrecision(-1e100)); } catch (e) { print(e.name); }
