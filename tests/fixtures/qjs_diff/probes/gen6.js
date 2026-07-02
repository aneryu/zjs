var p=new Proxy({}, {ownKeys:()=>['a'], getOwnPropertyDescriptor:()=>({value:1,enumerable:true,configurable:true})});
var o=[]; for(var k in p)o.push(k); print("["+o.join(',')+"]");
