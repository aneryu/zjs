try{ print(JSON.parse('"\\ud800"').charCodeAt(0)) }catch(e){ print("threw:"+e.name) }
