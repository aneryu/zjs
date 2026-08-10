// L0: constructor that allocates but adds no own property.
// Pairs with L3 to price a new own property (shape transition) apart from
// allocation: (L3 - L0) / 3 is the per-new-property cost.
var N = 5000000;
function main(n) {
    function Empty() { }
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Empty();
        if (p) s++;
    }
    return s;
}
print(main(N));
