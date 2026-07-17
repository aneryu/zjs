(function () {
    let sum = 0;
    for (let i = 0; i < 5000000; i++) {
        let value = i & 255;
        sum = (sum + value) | 0;
    }
    print(sum);
})();
