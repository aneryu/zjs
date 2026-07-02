var log=[];
new Promise(r=>r(Promise.resolve('X'))).then(v=>log.push('adopted:'+v));
Promise.resolve().then(()=>log.push('t1')).then(()=>log.push('t2')).then(()=>{log.push('t3'); print(log.join('|'))});
