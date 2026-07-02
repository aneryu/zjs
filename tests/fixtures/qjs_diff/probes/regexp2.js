try{ var re=new RegExp(Symbol('x')); print("built:"+re.source) }catch(e){ print("threw:"+e.name) }
