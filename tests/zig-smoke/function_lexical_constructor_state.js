// Function lexical constructor metadata is internal state.
function C() {
  return () => new.target;
}
var arrow = new C();
print("__zjs_arrow_new_target" in arrow);
function Fake() {}
arrow.__zjs_arrow_new_target = Fake;
print(arrow() === C, arrow() === Fake);

class Base {
  constructor() {
    this.tag = "base";
  }
}
class Other {
  constructor() {
    this.tag = "other";
  }
}
class Derived extends Base {
  constructor() {
    super();
  }
}
print("__zjs_super_constructor" in Derived);
Derived.__zjs_super_constructor = Other;
var derived = new Derived();
print(derived.tag, derived instanceof Base, derived instanceof Derived);

class DerivedArrow extends Base {
  constructor() {
    var callSuper = () => super();
    print("__zjs_arrow_constructor_this" in callSuper);
    callSuper.__zjs_arrow_constructor_this = {};
    var result = callSuper();
    print(result.tag, result instanceof Base);
    return result;
  }
}
new DerivedArrow();
