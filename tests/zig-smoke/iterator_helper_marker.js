// Iterator helper method dispatch markers are internal metadata.
function printLayout(label, helper) {
  var proto = Object.getPrototypeOf(helper);
  print(label);
  print(Object.prototype.toString.call(helper));
  print("own:" + Object.getOwnPropertyNames(helper).join(","));
  print("proto:" + Object.getOwnPropertyNames(proto).join(","));
  print(helper.hasOwnProperty("next"));
  print(typeof proto.next);
  print(helper.next === proto.next);
}

function check(fn, marker, run) {
  print(marker in fn);
  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
  fn[marker] = 0;
  print(marker in fn);
  print(run());
  print(delete fn[marker]);
  print(marker in fn);
  print(run());
}

var helper = Iterator.from([1]).map(function(x) { return x + 1; });
printLayout("map", helper);
printLayout("concat", Iterator.concat([1]));
printLayout("zip", Iterator.zip([[1], [2]]));

var next = helper.next;

check(next, "__zjs_iterator_helper_method", function() {
  var h = Iterator.from([1]).map(function(x) { return x + 1; });
  return next.call(h).value;
});
