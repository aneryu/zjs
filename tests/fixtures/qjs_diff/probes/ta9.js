var ab=new ArrayBuffer(8,{maxByteLength:32}); try{ab.transfer(64); print("ok")}catch(e){print("threw:"+e.constructor.name)}
