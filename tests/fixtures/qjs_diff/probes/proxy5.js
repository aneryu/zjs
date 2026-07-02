var rv=Proxy.revocable({a:1},{ownKeys(t){rv.revoke(); return ['a'];}});
try{ print("["+Object.getOwnPropertyNames(rv.proxy).join(",")+"]") }catch(e){ print("threw:"+e.name) }
