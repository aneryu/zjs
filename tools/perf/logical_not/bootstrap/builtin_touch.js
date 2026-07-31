// bootstrap + a light touch of every major builtin family.
const a=[1,2,3]; a.map(function(v){return v*2;});
const s="abc".toUpperCase(); const o=JSON.parse(JSON.stringify({a:1}));
const m=new Map(); m.set("k",1); const d=new Date(0).getTime();
const r=/ab+c/.test("abbbc"); print(a.length+s.length+o.a+m.size+d+(r?1:0));
