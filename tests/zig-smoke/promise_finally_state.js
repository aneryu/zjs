var savedFulfill;
var savedReject;
var cleanupCount = 0;
var p = new Promise(function() {});

p.then = function(onFulfilled, onRejected) {
  savedFulfill = onFulfilled;
  savedReject = onRejected;
  return Promise.prototype.then.call(this, onFulfilled, onRejected);
};

p.finally(function() {
  cleanupCount += 1;
  print("cleanup", cleanupCount);
  return "cleanup-result";
});

print(typeof savedFulfill, typeof savedReject);
print("__zjs_promise_finally_mode" in savedFulfill);
print("__zjs_promise_finally_callback" in savedFulfill);
print("__zjs_promise_finally_constructor" in savedFulfill);
print("__zjs_promise_finally_mode" in savedReject);
print(Object.getOwnPropertyDescriptor(savedFulfill, "__zjs_promise_finally_mode") === undefined);
print(savedFulfill.__zjs_promise_finally_mode);

savedFulfill.__zjs_promise_finally_callback = function() {
  print("tampered");
  return "bad";
};
savedFulfill.__zjs_promise_finally_payload = "bad";
savedFulfill("direct");
print("after direct");
