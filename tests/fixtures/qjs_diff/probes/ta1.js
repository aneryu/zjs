var t=new Int32Array([5,9]); t.sort((a,b)=>{print('args:',a,b);return 0;});
var u=new Int32Array([2,1]); u.sort(()=>1); print("order:"+u.join(','));
