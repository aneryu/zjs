const m=new Map(); m.getOrInsertComputed('k',()=>{m.set('k','cb'); m.set('z',9); return 'computed';});
print(JSON.stringify([...m.entries()]));
