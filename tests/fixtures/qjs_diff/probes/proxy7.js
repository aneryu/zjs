try{ print("["+Object.getOwnPropertyNames(new Proxy({},{ownKeys:()=>1})).join(",")+"]") }catch(e){ print("threw:"+e.name) }
