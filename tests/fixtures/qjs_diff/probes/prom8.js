let r; const p=new Promise(res=>r=res); r(p);
p.catch(e=>print(e.name+':['+e.message+']'));
