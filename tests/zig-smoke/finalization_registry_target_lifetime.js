var ref;
var registry = new FinalizationRegistry(function () {});

(function () {
  var target = {};
  ref = new WeakRef(target);
  registry.register(target, "held");
})();

gc();
print(ref.deref() === undefined);
