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

pub const Header = struct {
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,
};

pub const FileDecoder = struct {
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

        for (0..runningArray.len) |i| {
            runningArray[i] = .{
                0,
                0,
                0,
                0,
            };
        }

        var currentPixel: u64 = 0;
        var prevPixel: [4]u8 = .{
            0,
            0,
            0,
            255,
        };

        var runLength: u6 = 0;
        var i: u64 = 0;

        while (i < buffer.len) {
            if (runLength > 0) {
                runLength -= 1;
                imageData[currentPixel] = prevPixel;
                i += 1;
            } else {
                switch (buffer[i]) {
                    QOI_OP_RGB => {
                        imageData[currentPixel] = .{
                            buffer[i + 1],
                            buffer[i + 2],
                            buffer[i + 3],
                            prevPixel[3],
                        };

                        prevPixel = imageData[currentPixel];
                        i += 4;
                    },
                    QOI_OP_RGBA => {
                        imageData[currentPixel] = .{
                            buffer[i + 1],
                            buffer[i + 2],
                            buffer[i + 3],
                            buffer[i + 4],
                        };

                        prevPixel = imageData[currentPixel];
                        i += 5;
                    },
                    else => {
                        const bitFlag: u2 = @intCast(buffer[i] >> 6);
                        const data: u6 = @intCast(buffer[i] & 0b00111111);
                        switch (bitFlag) {
                            QOI_OP_INDEX => {
                                imageData[currentPixel] = .{
                                    runningArray[data][0],
                                    runningArray[data][1],
                                    runningArray[data][2],
                                    runningArray[data][3],
                                };

                                prevPixel = imageData[currentPixel];
                                i += 1;
                            },
                            QOI_OP_DIFF => {
                                const rDiff: u2 = @intCast(data & 0b000011);
                                const gDiff: u2 = @intCast((data & 0b001100) >> 2);
                                const bDiff: u2 = @intCast(data >> 4);

                                prevPixel[0] +%= rDiff - 2;
                                prevPixel[1] +%= gDiff - 2;
                                prevPixel[2] +%= bDiff - 2;

                                imageData[currentPixel] = prevPixel;
                                i += 1;
                            },
                            QOI_OP_LUMA => {
                                const rDiff: u8 = (buffer[i + 1] & 0b00001111) + data;
                                const bDiff: u8 = (buffer[i + 1] >> 4) + data;
                                prevPixel[0] +%= rDiff - 8;
                                prevPixel[1] +%= data - 32;
                                prevPixel[2] +%= bDiff - 8;
                                prevPixel = imageData[currentPixel];
                                i += 2;
                            },
                            QOI_OP_RUN => {
                                runLength = data;
                                i += 1;
                            },
                        }
                    },
                }

                runningArray[getIndex(imageData[currentPixel])] = imageData[currentPixel];
            }

            currentPixel += 1;
        }
    }

    fn getIndex(color: [4]u8) u8 {
        return (color[0] * 3 + color[1] * 5 + color[2] * 7 + color[3] * 11) % 64;
    }
};

const FileEncoder = struct {};

pub fn main() !void {
    // const allocator = std.heap.page_allocator

    // std.debug.print("{any}\n", .{fileDecoder});

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
