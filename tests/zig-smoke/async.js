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

async function testForAwaitAsyncIterator() {
    let log = "";
    const iter = {
        i: 0,
        [Symbol.asyncIterator]() {
            return this;
        },
        next() {
            this.i++;
            return { value: this.i, done: this.i > 2 };
        },
    };
    for await (const value of iter) {
        log += value;
    }
    return log;
}

testForAwaitAsyncIterator().then((value) => console.log(value));

async function testForAwaitRejectedValueClosesSyncIterator() {
    let closed = 0;
    const iter = {
        i: 0,
        [Symbol.iterator]() {
            return this;
        },
        next() {
            this.i++;
            if (this.i === 1) {
                return { value: Promise.reject(new Error("boom")), done: false };
            }
            return { value: undefined, done: true };
        },
        return() {
            closed++;
            return { done: true };
        },
    };
    try {
        for await (const value of iter) {
            void value;
        }
    } catch (err) {
        console.log(err.message, closed);
    }
}

testForAwaitRejectedValueClosesSyncIterator();

async function testForAwaitRejectedAsyncNextIsCatchable() {
    let closed = 0;
    const iter = {
        [Symbol.asyncIterator]() {
            return this;
        },
        next() {
            return Promise.reject(new Error("next boom"));
        },
        return() {
            closed++;
            return { done: true };
        },
    };
    try {
        for await (const value of iter) {
            void value;
        }
    } catch (err) {
        console.log(err.message, closed);
    }
}

testForAwaitRejectedAsyncNextIsCatchable();

async function testForAwaitRejectedAsyncReturnIsCatchable() {
    const iter = {
        i: 0,
        [Symbol.asyncIterator]() {
            return this;
        },
        next() {
            this.i++;
            return Promise.resolve({ value: this.i, done: false });
        },
        return() {
            return Promise.reject(new Error("return boom"));
        },
    };
    try {
        for await (const value of iter) {
            void value;
            break;
        }
    } catch (err) {
        console.log(err.message);
    }
}

testForAwaitRejectedAsyncReturnIsCatchable();

async function testForAwaitStartErrorIsCatchable() {
    const iter = {};
    Object.defineProperty(iter, Symbol.asyncIterator, {
        get() {
            throw new Error("start boom");
        },
    });
    try {
        for await (const value of iter) {
            void value;
        }
    } catch (err) {
        console.log(err.message);
    }
}

testForAwaitStartErrorIsCatchable();
