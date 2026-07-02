var t=new Int32Array([1,2]); print('push' in t, 'flat' in t);
try{ t.splice(0,1); print("splice-ok:"+t.join(',')) }catch(e){ print("splice-threw:"+e.name) }
