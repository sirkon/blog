const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts.zig");
const decoding = @import("decoding.zig");

/// Calculates the exact encoded size of an anonymous struct in bytes.
/// The entire type system is unwound at comptime, only size additions remain at runtime.
pub fn getStructEncodedSize(struct_val: anytype) usize {
    const T = @TypeOf(struct_val);
    const structInfo = @typeInfo(T);

    comptime {
        if (structInfo != .@"struct") {
            @compileError("getStructEncodedSize expects an anonymous struct, received type: " ++ @typeName(T));
        }
    }

    var totalSize: usize = 0;

    // Iterate over all fields of the anonymous struct at comptime
    inline for (structInfo.@"struct".fields) |field| {
        // Each field starts with: 1 byte (typeCode) + varint(len(name)) + the name itself
        const nameLen = field.name.len;
        totalSize += 1; // typeCode: u8
        totalSize += varintSize(nameLen); // uvarint(len(item.name))
        totalSize += nameLen; // "${item.name}"

        // Get the field value
        const val = @field(struct_val, field.name);
        const FieldType = field.type;

        switch (@typeInfo(FieldType)) {
            .bool => {
                totalSize += 1;
            },
            .int => |info| {
                comptime std.debug.assert(info.bits <= 64);
                if (info.bits <= 8) {
                    totalSize += 1;
                } else if (info.bits <= 16) {
                    totalSize += 2;
                } else if (info.bits <= 32) {
                    totalSize += 4;
                } else {
                    totalSize += 8;
                }
            },
            .comptime_int => {
                totalSize += @sizeOf(consts.MinimalInt(val));
            },
            .float => |info| {
                if (info.bits == 32) {
                    totalSize += 4;
                } else {
                    totalSize += 8;
                }
            },
            .@"struct" => {
                // Nested anonymous struct support (Groups)
                // Recursively calculate the size of the nested structure contents
                totalSize += getStructEncodedSize(val);

                // Add 1 byte for the trailing typeCodeGroupEnd marker
                totalSize += 1;
            },
            .pointer => |ptrInfo| {
                // Check if this type can be treated as a string/slice of bytes
                const is_string = comptime (ptrInfo.child == u8 or switch (@typeInfo(ptrInfo.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                });

                // Variant B: String literal or []const u8
                if (comptime is_string) {
                    // A string or byte slice adds its varint length + the length of the bytes
                    totalSize += varintSize(val.len);
                    totalSize += val.len;
                }
                // Variant A: Regular dynamic slice ([]T) where T is NOT u8
                else if (ptrInfo.size == .slice) {
                    const Child = ptrInfo.child;

                    // varint of the slice length itself (v.len)
                    totalSize += varintSize(val.len);

                    // Calculate the size of the slice contents
                    switch (@typeInfo(Child)) {
                        .bool => totalSize += val.len * 1,
                        .int => |info| {
                            const item_size: usize =
                                if (info.bits <= 8) 1 else if (info.bits <= 16) 2 else if (info.bits <= 32) 4 else 8;
                            totalSize += val.len * item_size;
                        },
                        .float => |info| {
                            const item_size: usize = if (info.bits == 32) 4 else 8;
                            totalSize += val.len * item_size;
                        },
                        else => @compileError("Slices of type " ++ @typeName(Child) ++
                            " inside anonymous structs are not supported by the rules."),
                    }
                } else {
                    @compileError("Pointers other than dynamic slices ([]T) and strings are not " ++
                        "supported by the rules. Field: " ++ field.name);
                }
            },
            .array => |arrInfo| {
                // Fixed-size arrays encode like slices: varint(len) + len items.
                const Child = arrInfo.child;
                totalSize += varintSize(arrInfo.len);

                switch (@typeInfo(Child)) {
                    .bool => totalSize += arrInfo.len * 1,
                    .int => |info| {
                        const item_size: usize =
                            if (info.bits <= 8) 1 else if (info.bits <= 16) 2 else if (info.bits <= 32) 4 else 8;
                        totalSize += arrInfo.len * item_size;
                    },
                    .float => |info| {
                        const item_size: usize = if (info.bits == 32) 4 else 8;
                        totalSize += arrInfo.len * item_size;
                    },
                    else => @compileError("Arrays of type " ++ @typeName(Child) ++
                        " inside anonymous structs are not supported by the rules."),
                }
            },
            else => @compileError("Unsupported base type in anonymous struct: " ++ @typeName(FieldType)),
        }
    }

    return totalSize;
}

/// Takes raw pointer to the initial position, encodes given value into it, return
/// a new pointer value just after the data it just put.
///
/// ### Supported types:
///
/// Basic:
///  - bool
///  - i8 ... i64
///  - u8 ... u64
///  - f32 and f64
///  - strings
///
/// Slices containing basic types.
pub fn append(dst: [*]u8, v: anytype) [*]u8 {
    const T = @TypeOf(v);
    var ptr = dst;

    switch (@typeInfo(T)) {
        .bool => {
            ptr[0] = @intFromBool(v);
            return ptr + 1;
        },
        .int => |info| {
            comptime std.debug.assert(info.bits <= 64);
            if (info.bits == 8) {
                ptr[0] = @bitCast(v);
                return ptr + 1;
            } else {
                const size = info.bits / 8;
                const leVal = std.mem.nativeTo(T, v, .little);
                @memcpy(ptr[0..size], std.mem.asBytes(&leVal));
                return ptr + size;
            }
        },
        .comptime_int => {
            return append(dst, consts.minimalInt(v));
        },
        .float => |info| {
            const size = info.bits / 8;
            if (info.bits == 32) {
                const uVal: u32 = @bitCast(v);
                @memcpy(ptr[0..4], std.mem.asBytes(&uVal));
            } else {
                const uVal: u64 = @bitCast(v);
                @memcpy(ptr[0..8], std.mem.asBytes(&uVal));
            }
            return ptr + size;
        },
        .pointer => |ptrInfo| {
            if (ptrInfo.size == .slice) {
                const Child = ptrInfo.child;

                if (comptime !isBasicType(Child)) {
                    @compileError("Slices of " ++ @typeName(Child) ++ " are not supported.");
                }

                ptr = appendVarint(ptr, v.len);

                if (v.len == 0) return ptr;

                const isFlatType = comptime switch (@typeInfo(Child)) {
                    .int, .float, .bool => true,
                    else => false,
                };

                if (comptime isFlatType and
                    (Child == u8 or Child == i8 or Child == bool or builtin.target.cpu.arch.endian() == .little))
                {
                    const bytes = std.mem.sliceAsBytes(v);
                    @memcpy(ptr[0..bytes.len], bytes);
                    return ptr + bytes.len;
                } else {
                    for (v) |item| {
                        ptr = append(ptr, item);
                    }
                    return ptr;
                }
            }

            // 🌟 FIXED FOR ZIG 0.16.0: String literals and const byte pointers support
            // Uses safe pattern matching to extract the inner array data without out-of-bounds errors.
            const is_string = comptime (ptrInfo.child == u8 or switch (@typeInfo(ptrInfo.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            });

            if (comptime is_string) {
                // A string must be prefixed with its varint length to match getStructEncodedSize!
                ptr = appendVarint(ptr, v.len);

                if (v.len > 0) {
                    @memcpy(ptr[0..v.len], v);
                    ptr += v.len;
                }
                return ptr;
            }

            @compileError("Unsupported pointer type " ++ @typeName(T) ++ ".");
        },
        .array => |arrInfo| {
            // Fixed-size arrays share the slice wire layout: varint(len) + items.
            const slice: []const arrInfo.child = &v;
            return append(dst, slice);
        },
        else => @compileError("Unsupported type " ++ @typeName(T) ++ "."),
    }
}

/// Encodes unsigned integers using uleb128 (uvarint) encoding and zigzag encoding for signed integers.
///
/// ### Supported types:
/// - i8 ... i64
/// - u8 ... u64
pub inline fn appendVarint(dst: [*]u8, v: anytype) [*]u8 {
    const T = @TypeOf(v);
    const info = @typeInfo(T);

    // Check it is an integer type.
    if (info != .int) {
        @compileError("appendVarint works with integer types only, got " ++ @typeName(T) ++ ".");
    }

    var ptr = dst;
    var val: u64 = undefined;

    if (info.int.signedness == .signed) {
        // Zigzag for i8, i16, i32, i64.
        const bits = info.int.bits;
        const casted = @as(u64, @bitCast(@as(i64, v)));
        val = (casted << 1) ^ @as(u64, @bitCast(@as(i64, v) >> (bits - 1)));
    } else {
        // Raw uleb128 for unsigned ints.
        val = @as(u64, v);
    }

    // Use generic LEB once everything is encoded.
    while (val >= 0x80) {
        ptr[0] = @as(u8, @truncate(val)) | 0x80;
        ptr += 1;
        val >>= 7;
    }
    ptr[0] = @as(u8, @truncate(val));
    return ptr + 1;
}

fn isBasicType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .bool, .int, .float => return true,
        .pointer => |ptrInfo| {
            if (ptrInfo.size == .slice and ptrInfo.child == u8) return true;
            if (ptrInfo.size == .one) {
                switch (@typeInfo(ptrInfo.child)) {
                    .array => |arrInfo| return arrInfo.child == u8,
                    else => return false,
                }
            }
            return false;
        },
        else => return false,
    }
}

pub inline fn varintSize(value: u64) usize {
    const bits = 64 - @clz(value | 1);
    return ((bits - 1) / 7) + 1;
}

const expect = std.testing.expect;

test "append test" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, 256);
    const ptr = buf.ptr;

    if (comptime builtin.cpu.arch.endian() != .little) {
        @compileError("append test only works on LE target architectures");
    }

    try tryInteger(ptr, true);
    try tryInteger(ptr, @as(u8, 16));
    try tryInteger(ptr, @as(u16, 256));
    try tryInteger(ptr, @as(u32, 65536));
    try tryInteger(ptr, @as(u64, 0x100000000));
    try tryInteger(ptr, @as(i8, 16));
    try tryInteger(ptr, @as(i16, 256));
    try tryInteger(ptr, @as(i32, 65536));
    try tryInteger(ptr, @as(i64, 0x100000000));
    try tryFloat(ptr, @as(f64, 3.141592));
    try tryFloat(ptr, @as(f32, 2.71828));
    try tryBytes(ptr, "Hello");

    try tryVarint(ptr, @as(u8, 16));
    try tryVarint(ptr, @as(u16, 256));
    try tryVarint(ptr, @as(u32, 65536));
    try tryVarint(ptr, @as(u64, 0x100000000));
    try tryVarint(ptr, @as(i8, 16));
    try tryVarint(ptr, @as(i16, 256));
    try tryVarint(ptr, @as(i32, 65536));
    try tryVarint(ptr, @as(i64, 0x100000000));
}

test "test basic type check" {
    try expect(isBasicType(bool));
    try expect(isBasicType(u8));
    try expect(isBasicType(u16));
    try expect(isBasicType(u32));
    try expect(isBasicType(u64));
    try expect(isBasicType(i8));
    try expect(isBasicType(i16));
    try expect(isBasicType(i32));
    try expect(isBasicType(i64));
    try expect(isBasicType(f32));
    try expect(isBasicType(f64));
    try expect(isBasicType(@TypeOf("string")));
    try expect(!isBasicType(std.Target));
}

test "u64 varint edge cases with expected bytes validation" {
    const expectEqual = std.testing.expectEqual;
    const expectEqualSlices = std.testing.expectEqualSlices;

    // Structure for describing a test case
    const TestCase = struct {
        val: u64,
        expectedBytes: []const u8,
    };

    // Exact reference bytes for each critical u64 point
    const cases = [_]TestCase{
        // 1. Zero takes exactly 1 byte
        .{ .val = 0, .expectedBytes = &.{0x00} },

        // 2. Boundary between 1 and 2 bytes
        .{ .val = 0x7F, .expectedBytes = &.{0x7F} },
        .{ .val = 0x80, .expectedBytes = &.{ 0x80, 0x01 } },

        // 3. Boundary between 2 and 3 bytes
        .{ .val = 0x3FFF, .expectedBytes = &.{ 0xFF, 0x7F } },
        .{ .val = 0x4000, .expectedBytes = &.{ 0x80, 0x80, 0x01 } },

        // 4. Boundary between 3 and 4 bytes
        .{ .val = 0x1FFFFF, .expectedBytes = &.{ 0xFF, 0xFF, 0x7F } },
        .{ .val = 0x200000, .expectedBytes = &.{ 0x80, 0x80, 0x80, 0x01 } },

        // 5. Boundary between 4 and 5 bytes
        .{ .val = 0x0FFFFFFF, .expectedBytes = &.{ 0xFF, 0xFF, 0xFF, 0x7F } },
        .{ .val = 0x10000000, .expectedBytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x01 } },

        // 6. Filling the low 32 bits (5 bytes)
        .{ .val = 0xFFFFFFFF, .expectedBytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } },

        // 7. Maximum for i64 (9 bytes)
        .{
            .val = 0x7FFFFFFFFFFFFFFF,
            .expectedBytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F },
        },

        // 8. Absolute maximum of u64 (10 bytes).
        // The last byte contains only 1 bit (0x01), since 7 * 9 = 63 bits are packed, leaving 1 bit.
        .{
            .val = std.math.maxInt(u64),
            .expectedBytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 },
        },
    };

    var buffer: [32]u8 = undefined;
    const basePtr = &buffer;

    inline for (cases) |tc| {
        // Fill the buffer with garbage before each test
        @memset(&buffer, 0xAA);

        // --- 1. WRITE CHECK (Encoding) ---
        const writePtr = appendVarint(basePtr, tc.val);
        const bytesWritten = @intFromPtr(writePtr) - @intFromPtr(basePtr);

        // Check that the length matches the reference
        try expectEqual(tc.expectedBytes.len, bytesWritten);

        // Compare the bytes in the buffer with the expected reference (Golden master)
        try expectEqualSlices(u8, tc.expectedBytes, buffer[0..bytesWritten]);

        // --- 2. READ CHECK (Decoding) ---
        var decodedVal: u64 = undefined;
        const readPtr = try decoding.decodeVarint(&decodedVal, basePtr);
        const bytesRead = @intFromPtr(readPtr) - @intFromPtr(basePtr);

        // Compare the returned value and read length
        try expectEqual(tc.val, decodedVal);
        try expectEqual(bytesWritten, bytesRead);
    }
}

test "calculate anonymous struct encoded size" {
    const anon_struct = .{
        .is_active = true, // bool (1 байт)
        .age = @as(u8, 42), // u8 (1 байт)
        .score = @as(i32, -100), // i32 (4 байта)
        .name = "ZigLang", // []const u8 -> varint(7) + 7 байт данных
    };

    const size = getStructEncodedSize(anon_struct);

    // Давай посчитаем глазами по твоим правилам:
    // Поле .is_active: typeCode(1) + varint(len("is_active"))(1) + len("is_active")(9) + bool(1) = 12
    // Поле .age:       typeCode(1) + varint(len("age"))(1) + len("age")(3) + u8(1) = 6
    // Поле .score:     typeCode(1) + varint(len("score"))(1) + len("score")(5) + i32(4) = 11
    // Поле .name:      typeCode(1) + varint(len("name"))(1) + len("name")(4) + varint(len("ZigLang"))(1) + data(7) = 14
    // Итого: 12 + 6 + 11 + 14 = 43 байта.

    try std.testing.expectEqual(@as(usize, 43), size);
}

test "calculate nested anonymous struct encoded size" {
    const nested_struct = .{
        .sub = .{
            .name = @as(u64, 4), // u64 (8 bytes)
        },
    };

    const size = getStructEncodedSize(nested_struct);

    // Let's count manually based on your updated rules:
    //
    // 1. Root Field ".sub":
    //    typeCodeGroup (1) + varint(len("sub"))(1) + len("sub")(3) = 5 bytes
    //
    // 2. Nested Content (inside getStructEncodedSize recursively):
    //    Field ".name": typeCodeU64 (1) + varint(len("name"))(1) + len("name")(4) + u64_data(8) = 14 bytes
    //
    // 3. Trailing Marker for ".sub":
    //    typeCodeGroupEnd (1) = 1 byte
    //
    // Total Expected Size: 5 + 14 + 1 = 20 bytes.

    try std.testing.expectEqual(@as(usize, 20), size);
}

fn tryInteger(dst: [*]u8, val: anytype) !void {
    // Too lazy to write a proper expect func.
    // Allow it to run only it if the target architecture is little endian.
    const endianness = builtin.cpu.arch.endian();
    if (endianness != .little) {
        return;
    }

    const shifted = append(dst, val);
    const bytesWritten = @intFromPtr(shifted) - @intFromPtr(dst);
    try expect(@sizeOf(@TypeOf(val)) == bytesWritten);

    const ptr: [*]const @TypeOf(val) = @ptrCast(@alignCast(dst));
    try expect(ptr[0] == val);
}

fn tryFloat(dst: [*]u8, val: anytype) !void {
    const T = @TypeOf(val);

    comptime {
        if (@typeInfo(T) != .float) {
            @compileError("tryFloat only accept f32 and f64, got " ++ @typeName(T));
        }
    }

    if (comptime builtin.target.cpu.arch.endian() != .little) {
        return;
    }

    const expectedBytes = std.mem.asBytes(&val);

    const shifted = append(dst, val);

    const bytesWritten = @intFromPtr(shifted) - @intFromPtr(dst);
    try expect(@sizeOf(T) == bytesWritten);

    const actualBytes = dst[0..bytesWritten];

    try expect(std.mem.eql(u8, expectedBytes, actualBytes));
}

fn tryBytes(dst: [*]u8, val: []const u8) !void {
    if (comptime builtin.target.cpu.arch.endian() != .little) {
        return;
    }

    // 1. append will write [varint length][bytes])
    const shifted = append(dst, val);
    const bytesWritten = @intFromPtr(shifted) - @intFromPtr(dst);

    // 2. Compute how long is that "varint length".
    var varintBuf: [10]u8 = undefined;
    const varintEnd = appendVarint(&varintBuf, val.len);
    const varintLen = @intFromPtr(varintEnd) - @intFromPtr(&varintBuf);

    // 3. Check if the length is equal to varintLen + val.len
    try expect((varintLen + val.len) == bytesWritten);

    // 4. Test if varint length is in the head of data.
    try std.testing.expectEqualSlices(u8, varintBuf[0..varintLen], dst[0..varintLen]);

    // 5. Test if val content is after the varint length on the dst.
    const actualBytes = dst[varintLen..bytesWritten];
    try expect(std.mem.eql(u8, val, actualBytes));
}

fn tryVarint(dst: [*]u8, val: anytype) !void {
    const shifted = appendVarint(dst, val);
    const bytesWritten = @intFromPtr(shifted) - @intFromPtr(dst);

    var placeholder = val;
    const decodeRes = try decoding.decodeVarint(&placeholder, dst);

    const bytesRead = @intFromPtr(decodeRes) - @intFromPtr(dst);
    try std.testing.expect(bytesWritten == bytesRead);
    try std.testing.expect(placeholder == val);
}
