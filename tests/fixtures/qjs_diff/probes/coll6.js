const fr=new FinalizationRegistry(()=>{}); const tok={};
fr.register(fr,'held',tok); print(fr.unregister(tok));
