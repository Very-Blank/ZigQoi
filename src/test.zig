const std = @import("std");
const qoi = @import("main.zig");

const encodedQoi = @embedFile("test.qoi");
const decodedQoi = @embedFile("test.bin");

test "Decoding" {
    const result: []qoi.Pixel, const body = try qoi.decode(encodedQoi[0 .. encodedQoi.len - 1], std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u8, decodedQoi, @ptrCast(result));

    try std.testing.expectEqual(16, body.height);
    try std.testing.expectEqual(16, body.width);
    try std.testing.expectEqual(.rgba, body.channels);
    try std.testing.expectEqual(.sRGB, body.colorSpace);
}

test "Encoding" {
    const result: []u8 = try qoi.encode(decodedQoi[0..decodedQoi.len], .{ .height = 16, .width = 16, .channels = .rgba, .colorSpace = .sRGB }, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, encodedQoi[0 .. encodedQoi.len - 1], result);
}
