// Test basic arrow function
const add = (a, b) => a + b;
print(add(1, 2));

// Test arrow function with block
const mul = (a, b) => {
    return a * b;
};
print(mul(3, 4));

// Test arrow function capturing variable
let x = 10;
const getX = () => x;
print(getX());
