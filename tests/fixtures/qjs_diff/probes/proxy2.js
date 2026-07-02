var r = Proxy.revocable; try{ var o = r({}, {}); print(typeof o.proxy); }catch(e){ print("threw:"+e.name) }
