var d=new Date(1514934322000);
print(d.getTimezoneOffset(), d.getHours(), d.toString());
print(Date.parse('Jan 1 2020'), Date.parse('2020-1-1'));
try{ print("coerce:"+Date.parse(({toString(){return "2020-01-01"}}))) }catch(e){ print("coerce-threw:"+e.name) }
print("locale:"+d.toLocaleString());
