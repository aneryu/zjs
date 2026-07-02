try { print([...new Set([1]).union({size:-1, has(){return false}, keys(){return [][Symbol.iterator]()}})].join(",")) } catch(e){ print("threw:"+e.constructor.name) }
