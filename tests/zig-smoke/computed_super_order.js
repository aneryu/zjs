// computed super[expr] checks the receiver before invoking the method.
var calls = [];

class Base {
    constructor() { this.ready = true; }
    hit(x) { calls.push("hit:" + x + ":" + this.ready); }
}

class Derived extends Base {
    constructor() {
        var key = { toString: function() { calls.push("key"); return "hit"; } };
        super();
        super[key](1);
        print(calls.join(","));
    }
}

new Derived();
