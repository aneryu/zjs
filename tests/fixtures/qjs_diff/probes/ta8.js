try{new ArrayBuffer(8).resize(-1)}catch(e){print("a:"+e.constructor.name)}
var ab=new ArrayBuffer(0,{maxByteLength:8}); try{ab.resize(1e300); print("b-ok",ab.byteLength)}catch(e){print("b:"+e.constructor.name)}
