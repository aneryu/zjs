function* gf(){ try { yield 1; } finally { yield 'F'; } }
var it=gf(); it.next(); it.return(9);
try{ print("3:"+JSON.stringify(it.next())) }catch(e){ print("threw:"+String(e)) }
