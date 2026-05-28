Object.defineProperty(Error.prototype, "stack", {
  configurable: true,
  get: function () {
    return "custom stack";
  },
});

throw new Error("cli");
