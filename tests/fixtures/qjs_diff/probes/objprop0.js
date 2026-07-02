var proto={p1:1},o=Object.create(proto);o.a=1;o.b=2;var s=[];
for(var k in o){s.push(k);if(k==='a')proto.p2=2;} print("R2:"+s.join(','));
var pa={y1:1},pb={y2:2},o2=Object.create(pa);o2.a=1;var s2=[];
for(var k2 in o2){s2.push(k2);if(k2==='a')Object.setPrototypeOf(o2,{y1:9});} print("R3:"+s2.join(','));
