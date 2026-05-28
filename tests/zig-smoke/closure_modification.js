// Test closure with modification
function counter() {
    let count = 0;
    return function() {
        count++;
        return count;
    };
}

const c = counter();
print(c());
print(c());
print(c());

// Test closure with arrow function
function makeAdder(x) {
    return (y) => x + y;
}

const add5 = makeAdder(5);
print(add5(3));
print(add5(10));
