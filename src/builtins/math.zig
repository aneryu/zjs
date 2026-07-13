//! Transitional compatibility shim. Math's function-list table and method
//! bodies live in `exec/math_ops.zig`, matching the QuickJS engine-owned
//! standard-global model.

const math_ops = @import("../exec/math_ops.zig");

pub const PI = math_ops.PI;
pub const E = math_ops.E;
pub const LN10 = math_ops.LN10;
pub const LN2 = math_ops.LN2;
pub const LOG2E = math_ops.LOG2E;
pub const LOG10E = math_ops.LOG10E;
pub const SQRT1_2 = math_ops.SQRT1_2;
pub const SQRT2 = math_ops.SQRT2;
pub const sum_precise_method_id = math_ops.sum_precise_method_id;
pub const internal_entries = math_ops.internal_entries;

pub const preparedOpCall = math_ops.preparedOpCall;
pub const mathArg = math_ops.mathArg;
pub const toMathNumber = math_ops.toMathNumber;
pub const qjsMathMinMax = math_ops.qjsMathMinMax;
pub const qjsMathMinMaxPrimitiveFast = math_ops.qjsMathMinMaxPrimitiveFast;
pub const qjsPrimitiveMathNumber = math_ops.qjsPrimitiveMathNumber;
pub const qjsFmin = math_ops.qjsFmin;
pub const qjsFmax = math_ops.qjsFmax;
pub const qjsMathPow = math_ops.qjsMathPow;
pub const qjsMathRound = math_ops.qjsMathRound;
pub const qjsMathHypot = math_ops.qjsMathHypot;
pub const qjsMathImul = math_ops.qjsMathImul;
pub const qjsMathSign = math_ops.qjsMathSign;
pub const qjsMathSumPrecise = math_ops.qjsMathSumPrecise;
pub const exactF64Sum = math_ops.exactF64Sum;
pub const exactF64ScaledInteger = math_ops.exactF64ScaledInteger;
pub const scaledIntegerToF64 = math_ops.scaledIntegerToF64;
pub const shouldRoundScaledIntegerUp = math_ops.shouldRoundScaledIntegerUp;
pub const call = math_ops.call;
pub const abs = math_ops.abs;
pub const exp = math_ops.exp;
pub const log2 = math_ops.log2;
pub const max = math_ops.max;
