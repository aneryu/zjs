let s=0; for (let i=0;i<200000;i++){ const b=new Uint8Array(32); b[0]=i&255; s+=b[0]; } print(s);
