Promise.any([Promise.reject(1)]).catch(e=>print(Object.prototype.hasOwnProperty.call(e,'message'), Object.getOwnPropertyDescriptor(e,'errors').enumerable));
