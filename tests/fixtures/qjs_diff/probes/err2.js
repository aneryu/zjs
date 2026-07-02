print(typeof globalThis.InternalError);
function rec(){return rec()+1} try{rec()}catch(e){print(e.name)}
