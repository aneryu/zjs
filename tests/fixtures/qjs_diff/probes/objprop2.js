print(delete 'ab'[0]); print(delete 'ab'.length);
(function(){'use strict'; try{ delete 'ab'[0]; print('nothrow'); }catch(e){ print('strict:'+e.constructor.name); }})();
