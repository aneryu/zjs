Error.stackTraceLimit=2;
function f1(){return new Error('x')} function f2(){return f1()} function f3(){return f2()} function f4(){return f3()}
print(f4().stack.split("\n").length);
