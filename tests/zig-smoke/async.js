// Async/await smoke tests
// Note: Full async/await requires event loop support
// This test checks that the syntax parses and compiles

async function testAsync() {
    return 42;
}

async function testAwait() {
    const result = await Promise.resolve(100);
    return result;
}

// Test that async functions can be called
const p = testAsync();
console.log(typeof p);

// Test Promise (already implemented)
const promise = new Promise((resolve, reject) => {
    resolve(123);
});
console.log(typeof promise);
