try{print("date:"+new Date(1n).getTime())}catch(e){print("date-threw:"+e.name)}
try{print("at:"+[1,2,3].at(1n))}catch(e){print("at-threw:"+e.name)}
try{print("parseInt:"+parseInt('10',2n))}catch(e){print("parseInt-threw:"+e.name)}
