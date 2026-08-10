function run() {
    const values = [1.25, 2.5];
    let result = 0.0;
    for (let i = 0; i < 20000000; i++) {
        result = values[i & 1] + 0.125;
    }
    return result;
}
print(run());
