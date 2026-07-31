const buf=new ArrayBuffer(64); let s=0; for (let i=0;i<200000;i++){ const v=new Uint8Array(buf); v[0]=i&255; s+=v[0]; } print(s);
