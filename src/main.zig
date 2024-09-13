const std = @import("std");

pub const Channels = enum {
    RGB,
    RGBA,
};

const Colorspace = enum {
    SRGBLA, //sRGB with linear alpha
    LALL, //all channels linear
};

const QOI_OP_RGB: u8 = 0b11111110;
const QOI_OP_RGBA: u8 = 0b11111111;

const QOI_OP_INDEX: u2 = 0b00;
const QOI_OP_DIFF: u2 = 0b01;
const QOI_OP_LUMA: u2 = 0b10;
const QOI_OP_RUN: u2 = 0b11;

const Header = struct {
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,
};

const FileDecoder = struct {
    header: Header,
    imageBinData: [][4]u8,
    allocator: std.mem.Allocator,

    pub fn init(filePath: []u8, allocator: std.mem.Allocator) !FileDecoder {
        const file = try std.fs.cwd().openFile(filePath, .{});

        const buffer = try allocator.alloc(u8, try file.getEndPos());
        _ = try file.readAll(buffer);

        if (!std.mem.eql(u8, buffer[0..4], "qoif")) {
            return error.NotQoiFile;
        }

        var fileDecoder: FileDecoder = FileDecoder{
            .header = .{
                .width = @byteSwap(std.mem.bytesToValue(u32, buffer[4..8])),
                .height = @byteSwap(std.mem.bytesToValue(u32, buffer[8..12])),
                .channels = if (buffer[12] == 3) Channels.RGB else if (buffer[12] == 4) Channels.RGBA else return error.InvalidQoiChannel,
                .colorspace = if (buffer[13] == 0) Colorspace.SRGBLA else if (buffer[13] == 1) Colorspace.LALL else return error.InvalidQoiColorspace,
            },
            .imageBinData = undefined,
            .allocator = allocator,
        };

        if (fileDecoder.header.channels != (4 or 3)) {
            return error.QoiIncorrectChannels;
        }

        fileDecoder.imageBinData = try decode(buffer, allocator);

        return fileDecoder;
    }

    pub fn deInit(self: *FileDecoder) void {
        self.allocator.free(self.imageBinData);
    }

    fn decode(buffer: []u8, width: u32, height: u32, allocator: std.mem.Allocator) ![][4]u8 {
        const imageData: [][4]u8 = allocator.alloc([4]u8, width * height);
        const runningArray: [][4]u8 = allocator.alloc([4]u8, 64);
        var prevPixel: [4]u8 = .{ 0, 0, 0, 255 };
        var runLength: u6 = 0;

        for (buffer) |bit| {
            if (runLength > 0) {
                //Add code here for run length encoding
                runLength -= 1;
            } else {
                switch (bit) {
                    QOI_OP_RGB => {
                        //
                    },
                    QOI_OP_RGBA => {
                        //
                    },
                    else => {
                        const bitFlag: u2 = @intCast(bit >> 6);
                        const data: u6 = @intCast(bit & 0b00111111);
                        switch (bitFlag) {
                            QOI_OP_INDEX => {
                                //
                            },
                            QOI_OP_DIFF => {
                                //
                            },
                            QOI_OP_LUMA => {
                                //
                            },
                            QOI_OP_RUN => {
                                runLength = data;
                            },
                        }
                    },
                }
            }
        }
    }

    fn getIndex(r: u8, g: u8, b: u8, a: u8) u8 {
        return (r * 3 + g * 5 + b * 7 + a * 11) % 64;
    }
};

const FileEncoder = struct {};

pub fn main() !void {
    // const allocator = std.heap.page_allocator

    // std.debug.print("{any}\n", .{fileDecoder});

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
