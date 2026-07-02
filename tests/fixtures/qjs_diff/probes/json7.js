try{ var o=JSON.rawJSON({toString(){return '123'}}); print("ok:"+JSON.stringify({x:o})) }catch(e){ print("threw:"+e.name) }
