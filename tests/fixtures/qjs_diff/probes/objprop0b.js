var protoA={x1:1},o=Object.create(protoA);o.a=1;var s=[];
for(var k in o){s.push(k);if(k==='a')Object.setPrototypeOf(o,{y1:9});} print("R3:"+s.join(','));
