var ab=new ArrayBuffer(8), t=new Int32Array(ab); ab.transfer();
try{Atomics.load(t,0)}catch(e){print("load:"+e.constructor.name)}
