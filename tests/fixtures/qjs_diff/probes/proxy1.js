var inner=new Proxy({},{ownKeys(){return ['ghost']},getOwnPropertyDescriptor(t,k){return k==='ghost'?{value:1,configurable:false}:undefined}});
var outer=new Proxy(inner,{ownKeys(){return []}});
try{ print("["+Object.getOwnPropertyNames(outer).join(",")+"]") }catch(e){ print("threw:"+e.name) }
