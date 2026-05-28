function assertSame(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

function arithmeticLoop(iterations) {
  var acc = 0;
  for (var i = 0; i < iterations; i++) {
    acc = (acc + ((i * 13) ^ (i >>> 1))) | 0;
  }
  return acc;
}

function arrayLoop(iterations) {
  var values = [];
  for (var i = 0; i < iterations; i++) {
    values[i] = (i * 7) & 255;
  }

  var acc = 0;
  for (var j = 0; j < values.length; j++) {
    acc += values[j];
  }
  return acc;
}

function objectLoop(iterations) {
  var object = { a: 1, b: 2, c: 3 };
  var acc = 0;
  for (var i = 0; i < iterations; i++) {
    object.a = (object.a + object.b + i) & 1023;
    acc += object.a + object.c;
  }
  return acc;
}

function stringLoop(iterations) {
  var text = "";
  for (var i = 0; i < iterations; i++) {
    text += String.fromCharCode(97 + (i % 26));
    if (text.length > 64) text = text.slice(16);
  }
  return text.length + text.charCodeAt(0) + text.charCodeAt(text.length - 1);
}

var arithmetic = arithmeticLoop(20000);
var array = arrayLoop(4096);
var object = objectLoop(20000);
var string = stringLoop(5000);

assertSame(arithmetic, -1693725136, "arithmeticLoop");
assertSame(array, 522240, "arrayLoop");
assertSame(object, 10298096, "objectLoop");
assertSame(string, 261, "stringLoop");

console.log("perf microbench ok " + [arithmetic, array, object, string].join(" "));
