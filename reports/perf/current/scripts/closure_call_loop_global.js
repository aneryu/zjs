function makeAdder(k) {
    return function(x) {
        return k + x;
    };
}

var add = makeAdder(1);
var acc = 0;
for (var i = 0; i < 1000000; i++) {
    acc += add(i);
}
print(acc);
