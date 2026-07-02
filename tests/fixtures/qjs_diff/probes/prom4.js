const p=Promise.resolve(1); delete globalThis.Promise;
(async()=>{print('await ok:'+await p)})().then(()=>print('done'),e=>print('async rejected'));
