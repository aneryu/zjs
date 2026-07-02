try{new Uint8Array([1]).toBase64(null); print('ok')}catch(e){print("threw:"+e.constructor.name)}
