var it = {
  i: 0,
  [Symbol.iterator]: function() { return this; },
  next: function() {
    this.i++;
    return { done: this.i > 2, value: this.i };
  },
};

var a, b;
[a, b] = it;
print("values", a, b);
print(Object.getOwnPropertyNames(it).join(","));
print("__zjs_dstr_iterator" in it);
print("__zjs_dstr_index" in it);
print("__zjs_dstr_done" in it);

var sealed = Object.preventExtensions({
  i: 0,
  [Symbol.iterator]: function() { return this; },
  next: function() {
    this.i++;
    return { done: this.i > 2, value: this.i };
  },
});

try {
  var x, y;
  [x, y] = sealed;
  print("sealed", x, y, sealed.i);
} catch (e) {
  print(e.name);
}
print(Object.getOwnPropertyNames(sealed).join(","));

var rest;
[...rest] = "ab";
print("string rest", rest.join(""));

var closeLog = [];
var closeIt = {
  i: 0,
  [Symbol.iterator]: function() {
    closeLog.push("iterator");
    return this;
  },
  next: function() {
    this.i++;
    closeLog.push("next" + this.i);
    return { done: false, value: this.i };
  },
  return: function() {
    closeLog.push("return");
    return {};
  },
};

var first;
[first] = closeIt;
print("closed", first, closeLog.join(","));
