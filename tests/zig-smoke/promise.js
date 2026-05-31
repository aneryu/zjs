// Promise object smoke tests
const p = new Promise((resolve, reject) => {
    resolve(1);
});
console.log(typeof p);
console.log(p.then);
console.log(p.catch);
console.log(Promise.resolve(1));
console.log(Promise.all([1, 2]));
console.log(Promise.race([Promise.resolve(3), 4]));
console.log(Promise.reject(1));
