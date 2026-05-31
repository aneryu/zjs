var saved;
var p0 = new Promise(function() {});
p0.then = function(onFulfilled, onRejected) {
  saved = onFulfilled;
  return Promise.prototype.then.call(this, onFulfilled, onRejected);
};

var all = Promise.all([p0]);
print("__zjs_promise_comb_mode" in saved);
print("__zjs_promise_comb_state" in saved);
print("__zjs_promise_comb_called" in saved);
print(Object.getOwnPropertyDescriptor(saved, "__zjs_promise_comb_mode") === undefined);
print(saved.__zjs_promise_comb_mode);

saved.__zjs_promise_comb_called = 1;
saved.__zjs_promise_comb_state = null;
saved.__zjs_promise_comb_index = 99;
saved("ok");

var onFulfilled;
var onRejected;
var p1 = new Promise(function() {});
p1.then = function(fulfill, reject) {
  onFulfilled = fulfill;
  onRejected = reject;
  return Promise.prototype.then.call(this, fulfill, reject);
};

var settled = Promise.allSettled([p1]);
print("__zjs_promise_comb_mode" in onFulfilled);
print("__zjs_promise_comb_mode" in onRejected);

onFulfilled.__zjs_promise_comb_called = 1;
onRejected.__zjs_promise_comb_called = 1;
onRejected("bad");
onFulfilled("ignored");

all.then(
  function(values) { print("all", values[0]); },
  function(reason) { print("all rejected", reason); },
);
settled.then(
  function(values) { print("settled", values[0].status, values[0].value, values[0].reason); },
  function(reason) { print("settled rejected", reason); },
);
