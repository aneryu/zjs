class R extends RegExp {}; var r = new R('a');
try{ r.compile('b'); print(r.source) }catch(e){ print("threw:"+e.name) }
