var e=new Error('m'); var d=Object.getOwnPropertyDescriptor(e,'stack'); print(d?typeof d.value:'none');
delete e.stack; print(typeof e.stack);
