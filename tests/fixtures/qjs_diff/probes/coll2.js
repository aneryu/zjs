const g = Map.groupBy; try{ print(JSON.stringify([...g([1,2,3], x=>x%2).entries()])) }catch(e){ print("threw:"+e.name) }
