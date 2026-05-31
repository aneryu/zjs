var target = {};

[[target][0].x] = [12];
print("array literal member", target.x);

[...{ holder: target }.holder.rest] = [1, 2, 3];
print("array rest member", target.rest.join(","));

({ ...{ holder: target }.holder.objRest } = { a: 1, b: 2 });
print("object rest member", target.objRest.a, target.objRest.b);

var logs = [];
function log(value) {
  logs.push(value);
}

var store = new Proxy({}, {
  set: function(that, name, value) {
    log("set " + name);
    that[name] = value;
    return true;
  },
});

var iterator = {};
Object.defineProperty(iterator, "next", {
  get: function() {
    log("get next");
    return function() {
      log("call next");
      return { done: false, value: "A" };
    };
  },
});
Object.defineProperty(iterator, "return", {
  get: function() {
    log("get return");
    return function() {
      log("call return");
      return {};
    };
  },
});

var iterable = {};
Object.defineProperty(iterable, Symbol.iterator, {
  get: function() {
    log("get iterator");
    return function() {
      log("call iterator");
      return iterator;
    };
  },
});

[(log("lhs"), store).a] = iterable;
print("order", logs.join(","));
print("assigned", store.a);

var superLog = [];
class Base {
  set a(value) {
    superLog.push(value);
  }
}
class Derived extends Base {
  run() {
    [super.a] = [7];
  }
}
new Derived().run();
print("super", superLog.join(","));

function assignThis() {
  [this.x] = [8];
  [...this.y] = [9, 10];
  ({ a: this.z } = { a: 11 });
}
var thisTarget = {};
assignThis.call(thisTarget);
print("this", thisTarget.x, thisTarget.y.join(","), thisTarget.z);
