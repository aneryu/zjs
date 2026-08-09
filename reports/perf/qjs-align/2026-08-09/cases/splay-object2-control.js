function run() {
    let sum = 0;
    for (let i = 0; i < 10000000; i++) {
        sum += i + (i + 1);
    }
    return sum;
}
print(run());
