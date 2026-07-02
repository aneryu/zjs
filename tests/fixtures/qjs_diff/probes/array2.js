var a=[1,2,3]; Object.defineProperty(a,1,{writable:false});
try{a.fill(7);print("fill-ok",a.join(","))}catch(e){print("fill-threw:"+e.name,a.join(","))}
var f=Object.freeze([1,2,3]);
try{f.reverse();print("rev-ok")}catch(e){print("rev-threw:"+e.name)}
