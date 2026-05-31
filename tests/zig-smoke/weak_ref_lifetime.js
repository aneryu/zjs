var ref;

(function () {
  var target = { value: 1 };
  ref = new WeakRef(target);
  print(ref.deref().value);
})();

gc();
print(ref.deref() === undefined);
