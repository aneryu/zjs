try{ print("a:"+JSON.stringify([1],null,'日'.repeat(12)).length) }catch(e){ print("a-threw:"+e.name) }
try{ print("b:"+JSON.stringify([1],null,'éé').length) }catch(e){ print("b-threw:"+e.name) }
try{ print("c:"+JSON.stringify({k:[1,2]},null,' ').length) }catch(e){ print("c-threw:"+e.name) }
