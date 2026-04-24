// URI encode/decode smoke tests
console.log(encodeURI("a b?x=1&y=2#z"));
console.log(encodeURIComponent("a b?x=1&y=2#z"));
console.log(decodeURI("a%20b?x=1&y=2#z"));
console.log(decodeURI("%3F"));
console.log(decodeURIComponent("a%20b%3Fx%3D1%26y%3D2%23z"));
try {
  decodeURIComponent("%E0%A4%A");
} catch (e) {
  console.log(e.name + ": " + e.message);
}
try {
  decodeURI("%GG");
} catch (e) {
  console.log(e.name + ": " + e.message);
}
