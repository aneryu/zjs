function run() {
    let sum = 0;
    for (let i = 0; i < 10000000; i++) {
        const object = { a: i, b: i + 1 };
        sum += object.a + object.b;
    }
    return sum;
}
print(run());
