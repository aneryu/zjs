var p=new Proxy(function foo(){},{get(t,k,r){print('get:'+String(k));return Reflect.get(t,k,r)}});
print(Function.prototype.toString.call(p).slice(0,20));
