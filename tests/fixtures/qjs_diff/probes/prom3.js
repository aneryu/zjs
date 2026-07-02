var log=[];
Object.defineProperty(Promise.prototype,'then_probe',{value:1});
var orig=Promise.prototype.then;
Object.defineProperty(Promise.prototype,'then',{get(){log.push('then-getter');return orig;},configurable:true});
(async()=>{var v=await Promise.resolve(42); log.push('awaited:'+v); print(log.join('|'));})();
