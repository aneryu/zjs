// Test Array methods
const arr = [1, 2, 3, 4, 5];

// map
const doubled = arr.map(x => x * 2);
print(doubled);

// filter
const evens = arr.filter(x => x % 2 === 0);
print(evens);

// reduce
const sum = arr.reduce((acc, x) => acc + x, 0);
print(sum);

// forEach
arr.forEach(x => print(x));

// some
const hasEven = arr.some(x => x % 2 === 0);
print(hasEven);

// every
const allPositive = arr.every(x => x > 0);
print(allPositive);

const sparse = [, 1, , undefined];
print(sparse.length);
print(sparse.join("|"));
print(JSON.stringify(sparse));
print(sparse.indexOf(undefined));
print(sparse.includes(undefined));
print(sparse.lastIndexOf(undefined));
print([1, 2, 3].at(1));
print([1, 2, 3].at(-1));
print([1, 2, 3].slice(-2).join(","));
print([1, 2, 3].splice(1, 1, 9, 8).join(","));
const spliceTarget = [1, 2, 3];
spliceTarget.splice(1, 1, 9, 8);
print(spliceTarget.join(","));
