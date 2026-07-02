function count(){return arguments.length};
try{ print("apply:"+count.apply(null,{length:65536})) }catch(e){ print("threw:"+e.name) }
