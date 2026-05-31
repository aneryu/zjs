var resolve;
var p = new Promise(function(r) {
  resolve = r;
});

var q = p.then(function(v) {
  print("first", v);
  return v + "!";
});
p.then(function(v) {
  print("second", v);
});
q.then(function(v) {
  print("chain", v);
});
resolve("ok");
print("after resolve");

var reject;
var bad = new Promise(function(resolve, r) {
  reject = r;
});
bad.then(null, function(reason) {
  print("caught", reason);
  return "handled";
}).then(function(v) {
  print("recovered", v);
});
reject("boom");
print("after reject");

var passResolve;
var pass = new Promise(function(r) {
  passResolve = r;
});
pass.then().then(function(v) {
  print("pass", v);
});
passResolve("through");
print("after pass");
