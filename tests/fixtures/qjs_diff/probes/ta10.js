var ab=new ArrayBuffer(16,{maxByteLength:64}); var dv=new DataView(ab,8); ab.resize(4);
try{dv.getInt8(0)}catch(e){print("threw:"+e.constructor.name)}
