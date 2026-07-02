try { await import("./nonexistent-file.js"); } catch (e) { print("caught:", e.constructor.name); } print("survived");
