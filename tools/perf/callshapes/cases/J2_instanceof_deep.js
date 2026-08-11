// J2: instanceof against a constructor three prototype levels up.
// J2 - J takes out everything but the extra chain steps, so the pair prices
// the walk itself independently of the @@hasInstance lookup and the call
// boundary that both cases pay once.
var N = 15000000;
function main(n) {
    function Base() {}
    function Mid() {}
    Mid.prototype = Object.create(Base.prototype);
    function Leaf() {}
    Leaf.prototype = Object.create(Mid.prototype);
    var o = new Leaf();
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (o instanceof Base) s++;
    }
    return s;
}
print(main(N));
