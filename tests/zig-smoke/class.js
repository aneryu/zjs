// Class smoke tests - basic constructor instantiation
class MyClass {
    constructor(x) {
        this.x = x;
    }
}

const obj = new MyClass(42);
console.log(obj !== undefined);
console.log(obj.x);
