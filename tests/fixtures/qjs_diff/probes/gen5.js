function f(){}
try { new f(...[1,2]); print('A ok'); } catch(e){ print('A caught'); }
