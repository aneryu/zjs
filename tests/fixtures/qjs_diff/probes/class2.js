class A { constructor(){ Object.preventExtensions(this); } } class B extends A { x = 1; }
try{ print(new B().x) }catch(e){ print("threw:"+e.name) }
