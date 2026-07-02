delete RegExp.prototype[Symbol.match];
try{ print("match:"+JSON.stringify('a'.match(/a/))) }catch(e){ print("match-threw:"+e.name) }
delete RegExp.prototype[Symbol.split];
try{ print("split:"+JSON.stringify('a,b'.split(/,/))) }catch(e){ print("split-threw:"+e.name) }
