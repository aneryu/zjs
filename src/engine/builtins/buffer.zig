pub const ArrayBuffer = struct {
    bytes: []u8,
    detached: bool = false,

    pub fn byteLength(self: ArrayBuffer) usize {
        return if (self.detached) 0 else self.bytes.len;
    }

    pub fn detach(self: *ArrayBuffer) void {
        self.detached = true;
    }
};
