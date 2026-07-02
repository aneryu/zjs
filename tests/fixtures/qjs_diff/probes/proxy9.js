var v=[];for(var i=0;i<1200;i++)v=new Proxy(v,{});
try{ print(Array.isArray(v)) }catch(e){ print("threw:"+e.name) }
