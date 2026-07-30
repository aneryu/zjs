function f(a){return a+1;} function run(){let a=0; for(let i=0;i<2000000;i++) a=f(a); return a;} print(run());
