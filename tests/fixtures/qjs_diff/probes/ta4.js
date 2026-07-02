var ta=new Int32Array(new SharedArrayBuffer(16));
try{print("wait:"+Atomics.wait(ta,0,999,0))}catch(e){print("threw:"+e.constructor.name)}
