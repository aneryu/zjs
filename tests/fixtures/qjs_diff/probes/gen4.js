async function* ag(){ yield 1; }
ag().return(Promise.resolve(7)).then(r=>print('ret-start:'+r.value+','+r.done));
