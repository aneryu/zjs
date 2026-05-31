function C(executor) {
  print(typeof executor);
  print("__zjs_promise_capability_slot" in executor);
  print(Object.getOwnPropertyDescriptor(executor, "__zjs_promise_capability_slot") === undefined);
  print(executor.__zjs_promise_capability_slot === undefined);

  executor.__zjs_promise_capability_slot = null;
  try {
    executor(
      function(value) { print("resolve", value); },
      function(reason) { print("reject", reason); },
    );
    print("executor ok");
  } catch (e) {
    print("executor threw", e.name);
  }
}

C.resolve = function(value) {
  return value;
};

try {
  Promise.resolve.call(C, 1);
  print("done");
} catch (e) {
  print("outer", e.name);
}
