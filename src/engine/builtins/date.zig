pub const ms_per_day: i64 = 86_400_000;

pub fn dayFromTime(ms: i64) i64 {
    return @divFloor(ms, ms_per_day);
}

pub fn timeWithinDay(ms: i64) i64 {
    return @mod(ms, ms_per_day);
}
