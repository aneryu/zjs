console.log(typeof performance);
console.log(typeof performance.now);
console.log(typeof performance.timeOrigin);

var start = performance.now();
var end = performance.now();
console.log(typeof start);
console.log(start >= 0);
console.log(end >= start);
console.log(performance.timeOrigin > 0);
console.log("__zjs_performance_now" in performance.now);
performance.now.__zjs_performance_origin = Number.MAX_SAFE_INTEGER;
console.log(performance.now() >= 0);
console.log(delete performance.now.__zjs_performance_origin);

console.log(typeof atob);
console.log(typeof btoa);
console.log(btoa("hello"));
console.log(atob("aGVs bG8="));
console.log(btoa("\xff"));
console.log(atob("/w==").charCodeAt(0));
try {
  atob("*");
} catch (e) {
  console.log(e.name);
  console.log(e.message);
}
try {
  btoa("\u0100");
} catch (e) {
  console.log(e.name);
  console.log(e.message);
}

console.log(typeof queueMicrotask);
try {
  queueMicrotask(1);
} catch (e) {
  console.log(e.name);
  console.log(e.message);
}
var microtaskOrder = "";
Promise.resolve().then(function () {
  microtaskOrder += "p";
});
queueMicrotask(function () {
  microtaskOrder += "q";
});
queueMicrotask(function () {
  console.log(microtaskOrder);
});
console.log("sync");

console.log(typeof DOMException);
console.log(DOMException.length);
var domDefault = new DOMException();
console.log(domDefault.name);
console.log(domDefault.message);
console.log(domDefault.code);
console.log(domDefault instanceof DOMException);
console.log(Object.prototype.toString.call(domDefault));
var domInvalid = new DOMException("msg", "InvalidCharacterError");
console.log(domInvalid.name);
console.log(domInvalid.message);
console.log(domInvalid.code);
console.log(DOMException.INVALID_CHARACTER_ERR);
console.log(DOMException.prototype.INVALID_CHARACTER_ERR);
try {
  DOMException("x");
} catch (e) {
  console.log(e.name);
  console.log(e.message);
}
try {
  atob("*");
} catch (e) {
  console.log(e instanceof DOMException);
  console.log(e.code);
}
