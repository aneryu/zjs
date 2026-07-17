(function () {
    var values = ["left-value", "right-value"];
    let value = values[0];
    var checksum = 0;
    for (var i = 0; i < 5000000; i++) {
        value = values[i & 1];
        checksum = (checksum + value.length) | 0;
    }
    print(checksum);
})();
