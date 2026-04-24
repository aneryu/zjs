pub fn isLockFree(size: usize) bool {
    return size == 1 or size == 2 or size == 4 or size == 8;
}
