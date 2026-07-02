var log=[];var p=new Proxy({a:1},{ownKeys(t){log.push('ownKeys');return Reflect.ownKeys(t)},getOwnPropertyDescriptor(t,k){log.push('gopd:'+k);return Reflect.getOwnPropertyDescriptor(t,k)},isExtensible(t){log.push('isExt');return Reflect.isExtensible(t)}});
Object.isFrozen(p); print(log.join(','));
