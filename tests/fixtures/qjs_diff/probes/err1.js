var e=new TypeError('m'); print(Object.prototype.hasOwnProperty.call(e,'name'));
TypeError.prototype.name='Patched'; print(e.name);
