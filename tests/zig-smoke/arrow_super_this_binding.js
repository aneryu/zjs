// Arrow super() writes through the derived constructor this-binding cell.
class Base {
    constructor(x) { this.x = x; }
}

class Derived extends Base {
    constructor() {
        var callSuper = () => super("ok");
        try {
            throw 1;
        } catch (e) {
            for (var v of [0]) {
                try {} finally { callSuper(); }
            }
        }
        print(this.x);
    }
}

new Derived();
