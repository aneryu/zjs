// Class smoke tests - basic constructor instantiation
// Note: this.x = x still needs member expression assignment support
class MyClass {
    constructor(x) {
        // this.x = x; // TODO: member expression assignment not yet implemented
    }
}

const obj = new MyClass(42);
console.log(obj !== undefined);
