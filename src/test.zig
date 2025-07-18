const std = @import("std");
const qoi = @import("main.zig");

test "Decoding" {
    const buffer = @embedFile("test.qoi");
    const expected = @embedFile("test.bin");

    const result: []qoi.Pixel, _ = try qoi.decode(buffer[0 .. buffer.len - 1], std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, expected, @ptrCast(result));
}
