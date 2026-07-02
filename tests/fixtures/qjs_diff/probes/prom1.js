var log=[];
const t={then(res){log.push('thenable.then'); res(1);}};
new Promise(r=>r(t));
Promise.resolve().then(()=>log.push('tick1')).then(()=>{log.push('tick2'); print(log.join('|'))});
