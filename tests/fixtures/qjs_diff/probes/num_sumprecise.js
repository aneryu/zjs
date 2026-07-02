var arr=[],s=5; for(var i=0;i<500;i++){s^=s<<13;s|=0;s^=s>>>17;s^=s<<5;s|=0;arr.push(((s>>>0)-2147483648)*Math.pow(2,(s>>>0)%2000-1050));}
print(Math.sumPrecise(arr));
