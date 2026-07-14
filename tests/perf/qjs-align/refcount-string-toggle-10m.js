(function () {
    var values = ["left-value", "right-value"];
    var value = values[0];
    var sum = 0;
    for (var i = 0; i < 10000000; i++) {
        value = values[i & 1];
        sum = (sum + value.length) | 0;
    }
    print(sum);
})();
