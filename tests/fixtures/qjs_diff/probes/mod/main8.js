const m = await import("./data.json", { with: { type: "json" } }); print(JSON.stringify(m.default));
