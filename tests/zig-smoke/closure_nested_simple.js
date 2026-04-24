// Test nested closures without global variables
function f(a, b, c) {
    var x = 10;
    function g(d) {
        function h() {
            return d + x;
        }
        return h;
    }
    return g;
}

var g1 = f(1, 2, 3);
print(g1(5));
