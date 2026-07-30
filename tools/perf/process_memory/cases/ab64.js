let s=0; for (let i=0;i<200000;i++){ const b=new ArrayBuffer(64); s+=b.byteLength&1; } print(s);
