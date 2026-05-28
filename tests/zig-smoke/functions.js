function add(a, b) { return a + b; }
print(add(2, 3));

const double = x => x * 2;
print(double(21));

function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
print(fact(6));

function restYield(x, ...yield) { return yield + x; }
print(restYield(0, 42));

function restLet(x, ...let) { return let + x; }
print(restLet(0, 42));

var bindLog = [];
var bindTarget = new Proxy(function() {}, {
  getOwnPropertyDescriptor(target, key) {
    bindLog.push("desc:" + String(key));
    if (key === "length") return { value: 3, configurable: true };
  },
  get(target, key) {
    bindLog.push("get:" + String(key));
    if (key === "length") return 3;
    if (key === "name") return "hello world";
    return target[key];
  }
});
var boundProxy = Function.prototype.bind.call(bindTarget);
print(boundProxy.name);
print(boundProxy.length);
print(bindLog.join("|"));
