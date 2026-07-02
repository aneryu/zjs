print(Object.getOwnPropertyNames((function foo(a,b){}).bind(null,1)).join(','));
