const v=new Uint8Array(64); let s=0; for (let i=0;i<200000;i++){ v.fill(0); s+=v[0]; } print(s);
