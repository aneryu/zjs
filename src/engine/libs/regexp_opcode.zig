pub const Opcode = enum(u8) {
    char,
    any,
    split,
    match,
};

pub const Instruction = struct {
    opcode: Opcode,
    operand: u21 = 0,
};
