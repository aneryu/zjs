const mi=new Map([[1,2]]).keys(); const si=new Set([3]).values();
try{ print(JSON.stringify(Object.getPrototypeOf(mi).next.call(si))) }catch(e){ print("threw:"+e.name) }
