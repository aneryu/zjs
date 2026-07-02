var log=[];
function mk(name){var i=0;return {next(){i++;return i<=1?{value:name+i,done:false}:{value:undefined,done:true}},return(){log.push(name+'-return');return {done:true}},[Symbol.iterator](){return this}}}
var outer=mk('outer'); var inner=mk('inner');
outer.next=function(){return {value:inner,done:false}};
var fm=Iterator.prototype.flatMap.call(outer,x=>x);
fm.next(); fm.return(); print(log.join(','));
