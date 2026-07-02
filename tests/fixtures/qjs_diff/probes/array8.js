var log=[]; var p=new Proxy({length:2,0:"a",1:"b"},{get(t,k){log.push("get:"+String(k));return t[k];},has(t,k){log.push("has:"+String(k));return k in t;}});
Array.prototype.toReversed.call(p); print(log.join(" "));
