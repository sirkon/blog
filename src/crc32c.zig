const std = @import("std");
const builtin = @import("builtin");

/// Кроссплатформенный аппаратный CRC-32C (Castagnoli).
pub fn hardwareCrc32C(data: []const u8) u32 {
    // Включаем ассемблер ТОЛЬКО в режиме ReleaseFast под x86_64,
    // чтобы обойти баг компилятора Zig с обработкой MIR в Debug/ReleaseSafe.
    const is_x86_fast = builtin.target.cpu.arch == .x86_64 and builtin.mode == .ReleaseFast;

    // На ARM64 компилятор обрабатывает MIR отлично в любом режиме сборки
    const is_arm = builtin.target.cpu.arch == .aarch64;

    if (is_x86_fast) {
        var i: usize = 0;
        var crc64: u64 = 0xFFFFFFFF;
        while (i + 8 <= data.len) : (i += 8) {
            const val = std.mem.readInt(u64, data[i..][0..8], .native);
            asm (
                "crc32q %[val], %[crc]"
                : [crc] "+r" (crc64),
                : [val] "rm" (val),
            );
        }

        var crc32: u32 = @truncate(crc64);
        while (i < data.len) : (i += 1) {
            const val = data[i];
            asm (
                "crc32b %[val], %[crc]"
                : [crc] "+r" (crc32),
                : [val] "rm" (val),
            );
        }
        return crc32 ^ 0xFFFFFFFF;

    } else if (is_arm) {
        var i: usize = 0;
        var crc: u32 = 0xFFFFFFFF;
        while (i + 8 <= data.len) : (i += 8) {
            const val = std.mem.readInt(u64, data[i..][0..8], .native);
            asm (
                "crc32cx %[crc], %[crc], %[val]"
                : [crc] "+r" (crc),
                : [val] "r" (val),
            );
        }
        while (i < data.len) : (i += 1) {
            const val: u32 = data[i];
            asm (
                "crc32cb %[crc], %[crc], %[val]"
                : [crc] "+r" (crc),
                : [val] "r" (val),
            );
        }
        return crc ^ 0xFFFFFFFF;

    } else {
        // Безопасный фоллбек для x86_64 (в Debug/ReleaseSafe) и остальных архитектур
        return std.hash.crc.Crc32Iscsi.hash(data);
    }
}



test "crc32 Castagnoli hardware with the fallback for unsupported arches" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 133);

    // Правильно захватываем индекс итерации
    for (buf, 0..) |*val, index| {
        val.* = @intCast(index); // или buf[index] = @intCast(index);
    }

    // Теперь внутри буфера честные 0, 1, 2 ... 132
    const crc32c = hardwareCrc32C(buf);
    try std.testing.expectEqual(60592851, crc32c);
}
