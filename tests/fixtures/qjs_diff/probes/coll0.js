const b=new Set([7,8,9]); b.has=()=>true; print(new Set([1,2]).isSubsetOf(b));
const c=new Set([7]); c.keys=function*(){yield 42;}; print([...new Set([1]).union(c)].join(","));
