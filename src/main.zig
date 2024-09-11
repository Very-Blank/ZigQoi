const std = @import("std");

const Channels = enum {
    RGB,
    RGBA,
};

const Colorspace = enum {
    SRGBLA, //sRGB with linear alpha
    LALL, //all channels linear
};

const Header = struct {
    width: u32,
    height: u32,
    channels: u8,
};

const FileDecoder = struct {
    header: Header,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const file = try std.fs.cwd().openFile("src/test.qoi", .{});

    const buffer = try allocator.alloc(u8, try file.getEndPos());
    _ = try file.readAll(buffer);

    if (!std.mem.eql(u8, buffer[0..4], "qoif")) {
        return error.NotQoiFile;
    }

    const fileDecoder: FileDecoder = FileDecoder{
        .header = .{
            .width = @byteSwap(std.mem.bytesToValue(u32, buffer[4..8])),
            .height = @byteSwap(std.mem.bytesToValue(u32, buffer[8..12])),
            .channels = buffer[12],
        },
    };

    std.debug.print("{any}\n", .{fileDecoder});

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
