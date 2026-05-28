// Destructuring default initializers infer anonymous function/class names.
function objectNames({a = function(){}, b = class {}, c = function*(){}} = {}) {
    print(a.name);
    print(b.name);
    print(c.name);
}

function arrayNames([a = function(){}, b = class {}, c = function*(){}] = []) {
    print(a.name);
    print(b.name);
    print(c.name);
}

objectNames();
arrayNames();
