function add(a, b) {
    return a + b;
}

var acc = 0;
for (var i = 0; i < 1000000; i++) {
    acc += add(i, 1);
}
print(acc);
