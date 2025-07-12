const std = @import("std");
const qoi = @import("main.zig");

test "Decoding" {
    const buffer = @embedFile("test.qoi");
    const expected = @embedFile("test.bin");

    const result, _ = try qoi.FileDecoder.decode(buffer[0 .. buffer.len - 1], std.testing.allocator);

    try std.testing.expectEqualSlices(u8, expected, result);
}
