var log=[];var props=new Proxy({a:{value:1},b:{value:2}},{ownKeys(t){log.push('ownKeys');return Reflect.ownKeys(t);},getOwnPropertyDescriptor(t,k){log.push('gopd:'+k);return Reflect.getOwnPropertyDescriptor(t,k);},get(t,k){log.push('get:'+k);return t[k];}});
Object.defineProperties({},props);print(log.join(','));
