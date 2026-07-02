var ab=new ArrayBuffer(8,{maxByteLength:64}); var ta=new Int32Array(ab);
try{print("store:"+Atomics.store(ta,{valueOf(){ab.resize(64);return 10;}},7))}catch(e){print("threw:"+e.constructor.name)}
