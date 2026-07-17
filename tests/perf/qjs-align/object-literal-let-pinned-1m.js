(function () {
    const pin = { value: -1 };
    let sum = 0;
    for (let i = 0; i < 1000000; i++) {
        let object = { value: i };
        sum = (sum + object.value) | 0;
    }
    print((sum + pin.value + 1) | 0);
})();
