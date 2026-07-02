var log=[],key={[Symbol.toPrimitive](){log.push('toPrim');return 'k';}};
try{null[key]=1;}catch(e){log.push('err');} print(log.join(','));
