var t={0:"a",1:"b"}; Object.defineProperty(t,"length",{get(){return 2;},set(v){},configurable:true});
try{ print("pop:", Array.prototype.pop.call(t)); }catch(e){ print("pop threw:", e.name); }
try{ print("push:", Array.prototype.push.call(t,"c")); }catch(e){ print("push threw:", e.name); }
