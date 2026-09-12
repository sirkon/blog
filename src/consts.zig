const std = @import("std");

pub const version: u16 = 1;

pub const logLevel = enum(u8) {
    trace = 10,
    debug = 20,
    info = 30,
    warning = 40,
    err = 50,
    panic = 60,
};

pub const ValueKind = enum(u8) {
    // Group 1: special types 0..31.
    time = 0,
    duration = 1,
    errorRaw = 2,
    ivar = 16,
    uvar = 17,

    // Group 2: basic types. 32..63.
    bool = 32,
    string = 33,
    int8 = 40,
    int16 = 41,
    int32 = 42,
    int64 = 43,
    uint8 = 48,
    uint16 = 49,
    uint32 = 50,
    uint64 = 51,
    float32 = 56,
    float64 = 57,

    // Group 3: slices of basic types.
    sliceBool = 64, // или sliceBool
    sliceString = 65,
    sliceInt8 = 72,
    sliceInt16 = 73,
    sliceInt32 = 74,
    sliceInt64 = 75,
    sliceUint8 = 80,
    sliceUint16 = 81,
    sliceUint32 = 82,
    sliceUint64 = 83,
    sliceFloat32 = 88,
    sliceFloat64 = 89,

    // Group 4: tree nodes and metadata: 128..255.
    nodeNew = 128,
    nodeWrap = 129,
    nodeContext = 130,
    nodeLocation = 131,
    nodeForeignErrorText = 132,
    nodePhantomContext = 133,
    nodeGroup = 134,
    nodeError = 135,
    nodeErrorEmbed = 136,
    nodeGroupEnd = 137,
};

/// Smallest fixed-width integer type able to represent the comptime value `v`.
/// Lets `.{ .count = 12 }` log the narrowest integer instead of forcing an
/// explicit `@as(u64, 12)` on the caller.
pub fn MinimalInt(comptime v: comptime_int) type {
    if (v < 0) {
        if (v >= std.math.minInt(i8)) return i8;
        if (v >= std.math.minInt(i16)) return i16;
        if (v >= std.math.minInt(i32)) return i32;
        if (v >= std.math.minInt(i64)) return i64;
        @compileError("comptime_int attribute does not fit in i64");
    }
    if (v <= std.math.maxInt(u8)) return u8;
    if (v <= std.math.maxInt(u16)) return u16;
    if (v <= std.math.maxInt(u32)) return u32;
    if (v <= std.math.maxInt(u64)) return u64;
    @compileError("comptime_int attribute does not fit in u64");
}

/// `v` coerced to its minimal fixed-width integer type.
pub fn minimalInt(comptime v: comptime_int) MinimalInt(v) {
    return v;
}

/// Wire kind for a comptime integer, chosen from its minimal type.
pub fn intKind(comptime v: comptime_int) ValueKind {
    return switch (MinimalInt(v)) {
        i8 => .int8,
        i16 => .int16,
        i32 => .int32,
        i64 => .int64,
        u8 => .uint8,
        u16 => .uint16,
        u32 => .uint32,
        u64 => .uint64,
        else => unreachable,
    };
}

test "comptime int picks the minimal kind" {
    try std.testing.expectEqual(ValueKind.uint8, intKind(0));
    try std.testing.expectEqual(ValueKind.uint8, intKind(255));
    try std.testing.expectEqual(ValueKind.uint16, intKind(256));
    try std.testing.expectEqual(ValueKind.uint16, intKind(65535));
    try std.testing.expectEqual(ValueKind.uint32, intKind(65536));
    try std.testing.expectEqual(ValueKind.int8, intKind(-1));
    try std.testing.expectEqual(ValueKind.int8, intKind(-128));
    try std.testing.expectEqual(ValueKind.int16, intKind(-129));
}

test "comptime int picks the minimal size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(MinimalInt(12)));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(MinimalInt(300)));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(MinimalInt(70000)));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(MinimalInt(1 << 40)));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(MinimalInt(-5)));
}
