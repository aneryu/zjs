var savedResolve;
var savedReject;
var promise = new Promise(function(resolve, reject) {
  savedResolve = resolve;
  savedReject = reject;
});

print("__zjs_promise_target" in savedResolve);
print("__zjs_promise_reject" in savedResolve);
print("__zjs_promise_state" in savedResolve);
print(Object.getOwnPropertyDescriptor(savedResolve, "__zjs_promise_target") === undefined);

savedResolve.__zjs_promise_target = null;
savedResolve.__zjs_promise_reject = true;
savedResolve.__zjs_promise_state = null;
print(savedResolve.__zjs_promise_target === null);

var fakeThenableJob = Array.isArray;
var fakeTarget = new Promise(function(resolve, reject) {});
fakeThenableJob.__zjs_promise_thenable_target = fakeTarget;
fakeThenableJob.__zjs_promise_thenable_this = { tag: 1 };
fakeThenableJob.__zjs_promise_thenable_then = function(resolve, reject) {
  print("fake thenable job called", this.tag);
  resolve(123);
};
print("native still native", fakeThenableJob([]));
fakeTarget.then(function(value) {
  print("fake target settled", value);
});

var fakeReactionJob = Array.isArray;
var fakeReactionRecord = {
  __zjs_promise_reaction_on_fulfilled: function(value) {
    print("fake reaction handler", value);
    return "handled";
  },
  __zjs_promise_reaction_resolve: function(value) {
    print("fake reaction resolve", value);
  },
  __zjs_promise_reaction_reject: function(reason) {
    print("fake reaction reject", reason);
  },
};
fakeReactionJob.__zjs_promise_reaction_record = fakeReactionRecord;
fakeReactionJob.__zjs_promise_reaction_value = "x";
fakeReactionJob.__zjs_promise_reaction_is_rejected = 0;
print("reaction native still native", fakeReactionJob([]));

savedResolve(42);
savedReject("ignored");
promise.then(
  function(value) { print("resolved", value); },
  function(reason) { print("rejected", reason); },
);

var rejectOnly;
var rejected = new Promise(function(resolve, reject) {
  rejectOnly = reject;
});

rejectOnly.__zjs_promise_target = null;
rejectOnly("bad");
rejected.then(
  function(value) { print("resolved", value); },
  function(reason) { print("rejected", reason); },
);
