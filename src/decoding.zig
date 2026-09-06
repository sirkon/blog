const std = @import("std");
const builtin = @import("builtin");

/// Decoding errors.
pub const DecodingError = error{
    VarintOverflow,
    VarintPlaceholderOverflow,
};

/// Decodes a data from the given srcPtr as uvarint/varint depending on the placeholder type.
/// The placeholder must be one of:
/// - *i8 ... *i64
/// - *u8 ... *u64
pub inline fn decodeVarint(placeholder: anytype, srcPtr: [*]u8) DecodingError![*]u8 {
    const PtrType = @TypeOf(placeholder);
    const ptrInfo = @typeInfo(PtrType);

    comptime {
        if (ptrInfo != .pointer or ptrInfo.pointer.size != .one) {
            @compileError("decodeVarint expects a pointer to integer type, got " ++ @typeName(PtrType));
        }
    }

    const T = ptrInfo.pointer.child;
    const info = @typeInfo(T);

    comptime {
        if (info != .int) {
            @compileError("decodeVarint expects a pointer to integer type, got " ++ @typeName(PtrType));
        }
    }

    const lebRes = try decodeLEB128(srcPtr);
    const uVal = lebRes.val;

    if (info.int.signedness == .signed) {
        const casted_signed = @as(i64, @bitCast(uVal));
        const unzigzagged = (uVal >> 1) ^ @as(u64, @bitCast(-(casted_signed & 1)));

        const shiftAmt = 64 - info.int.bits;
        const signExtended = (@as(i64, @bitCast(unzigzagged)) << @intCast(shiftAmt)) >> @intCast(shiftAmt);

        if (signExtended < std.math.minInt(T) or signExtended > std.math.maxInt(T)) {
            return error.VarintPlaceholderOverflow;
        }

        placeholder.* = @truncate(signExtended);
    } else {
        if (uVal > std.math.maxInt(T)) {
            return error.VarintPlaceholderOverflow;
        }

        placeholder.* = @truncate(uVal);
    }

    return lebRes.next;
}

const UvarintResult = struct {
    val: u64,
    next: [*]u8,
};

inline fn decodeLEB128(src: [*]u8) DecodingError!UvarintResult {
    comptime {
        if (builtin.target.cpu.arch.endian() != .little) {
            @compileError("decodeVarint only works on LE architectures.");
        }
    }

    const unaligned_ptr: *align(1) const u64 = @ptrCast(src);
    var v = unaligned_ptr.*;

    if ((v & 0x80) == 0) {
        return .{ .val = v & 127, .next = src + 1 };
    }
    if ((v & 0x8000) == 0) {
        return .{ .val = (v & 127) | (((v >> 8) & 127) << 7), .next = src + 2 };
    }

    var res = (v & 127) | (((v >> 8) & 127) << 7);

    var p = pair(v >> 16);
    res |= p.val << 14;
    if (p.off > 0) return .{ .val = res, .next = src + 2 + p.off };

    p = pair(v >> 32);
    res |= p.val << 28;
    if (p.off > 0) return .{ .val = res, .next = src + 4 + p.off };

    p = pair(v >> 48);
    res |= p.val << 42;
    if (p.off > 0) return .{ .val = res, .next = src + 6 + p.off };

    const next_unaligned_ptr: *align(1) const u64 = @ptrCast(src + 8);
    v = next_unaligned_ptr.*;

    p = pair(v & 0xFFFF);
    res |= p.val << 56;
    if (p.off > 0) return .{ .val = res, .next = src + 8 + p.off };

    return error.VarintOverflow;
}

inline fn pair(v: u64) struct { val: u64, off: usize } {
    if ((v & 0x80) == 0) {
        return .{ .val = v & 0x7F, .off = 1 };
    }
    if ((v & 0x8000) == 0) {
        return .{ .val = (v & 0x7F) | ((v >> 8 & 0x7F) << 7), .off = 2 };
    }
    return .{ .val = (v & 0x7F) | ((v >> 8 & 0x7F) << 7), .off = 0 };
}
