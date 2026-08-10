// E0: arguments.length in a zero-parameter function called with no arguments.
// Isolates the fixed cost of materializing the arguments object.
var N = 5000000;
function main(n) {
    function e() { return arguments.length; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += e();
    }
    return s;
}
print(main(N));
