var escaped;

(function () {
  var proto = {
    value() {
      return 123;
    },
  };
  var object = {
    method() {
      return super.value();
    },
  };
  Object.setPrototypeOf(object, proto);
  escaped = object.method;
})();

gc();
print(escaped.call({}));
