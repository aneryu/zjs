var log=[];var p=new Proxy({a:1},{isExtensible(t){log.push('isExt');return Reflect.isExtensible(t);},ownKeys(t){log.push('ownKeys');return Reflect.ownKeys(t);},getOwnPropertyDescriptor(t,k){log.push('gopd:'+String(k));return Reflect.getOwnPropertyDescriptor(t,k);}});
print(Object.isSealed(p),log.join(','));
