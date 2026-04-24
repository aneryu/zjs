// Test basic closure capture
function outer() {
    let x = 10;
    function inner() {
        return x;
    }
    return inner;
}

const fn1 = outer();
print(fn1());

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

// Test multiple captured variables
function multi() {
    let a = 1;
    let b = 2;
    let c = 3;
    return function() {
        return a + b + c;
    };
}

const m = multi();
print(m());
