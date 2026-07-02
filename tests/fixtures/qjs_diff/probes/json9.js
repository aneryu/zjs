var log=[];
JSON.parse('{"a":1,"b":2}',function(k,v){log.push('rev:'+k); if(k==='a'){Object.defineProperty(this,'b',{get(){log.push('getB');return 42},configurable:true,enumerable:true});} return v;});
print(log.join(','));
