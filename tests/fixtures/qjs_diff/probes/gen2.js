var order=[];
async function* ag(){ yield Promise.resolve('PV'); }
ag().next().then(r=>{order.push('yield-promise:'+r.value+','+r.done); print(order.join('|'))});
