const std = @import("std");

pub const Channels = enum {
    RGB,
    RGBA,
};

const Colorspace = enum {
    sRGB, //sRGB with linear alpha
    LINEAR, //all channels linear
};

const QOI_OP_INSTRUCTIONS = enum {
    QOI_OP_RGB,
    QOI_OP_RGBA,
    QOI_OP_INDEX,
    QOI_OP_DIFF,
    QOI_OP_LUMA,
    QOI_OP_RUN,
};

// flags
const QOI_OP_RGB: u8 = 0b11111110;
const QOI_OP_RGBA: u8 = 0b11111111;
const QOI_OP_INDEX: u8 = 0b00000000;
const QOI_OP_DIFF: u8 = 0b01000000;
const QOI_OP_LUMA: u8 = 0b10000000;
const QOI_OP_RUN: u8 = 0b11000000;

const QOI_END_MARKER: [8]u8 = [_]u8{0} ** 8;

pub const qoi_header = struct {
    magic: u8[4], // magic bytes "qoif"
    width: u32, // image width in pixels (BE)
    height: u32, // image height in pixels (BE)
    channels: u8, // 3 = RGB, 4 = RGBA
    colorspace: u8, // 0 = sRGB with linear alpha // 1 = all channels linear
};

// (1 + 3) = tag + rgb
const QOI_OP_RGB_SIZE: u8 = 1 + 3;
// (1 + 4) = tag + rgba
const QOI_OP_RGBA_SIZE: u8 = 1 + 4;
const QOI_HEADER_SIZE = @sizeOf(qoi_header);
const QOI_END_MARKER_SIZE = @sizeOf(QOI_END_MARKER);

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

    pub fn init(filePath: []const u8, allocator: std.mem.Allocator) !FileDecoder {
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
                .colorspace = if (buffer[13] == 0) Colorspace.sRGB else if (buffer[13] == 1) Colorspace.LINEAR else return error.InvalidQoiColorspace,
            },
            .imageBinData = undefined,
            .allocator = allocator,
        };

        fileDecoder.imageBinData = try decode(buffer[QOI_HEADER_SIZE .. buffer.len - QOI_END_MARKER], fileDecoder.header.width, fileDecoder.header.height, allocator);

        return fileDecoder;
    }

    pub fn deInit(self: *const FileDecoder) void {
        self.allocator.free(self.imageBinData);
    }

    fn decode(buffer: []u8, width: u32, height: u32, allocator: std.mem.Allocator) ![][4]u8 {
        const imageData: [][4]u8 = try allocator.alloc([4]u8, width * height);
        const runningArray: [][4]u8 = try allocator.alloc([4]u8, 64);
        for (0..runningArray.len) |i| {
            runningArray[i] = .{
                0,
                0,
                0,
                255,
            };
        }

        var currentPixel: u64 = 0;
        var prevPixel: [4]u8 = .{
            0,
            0,
            0,
            255,
        };

        var runLength: u8 = 0;
        var i: u64 = 0;

        while (i < buffer.len) {
            if (runLength > 0) {
                imageData[currentPixel] = prevPixel;

                currentPixel += 1;
                runLength -= 1;
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
                        runningArray[getIndex(imageData[currentPixel])] = imageData[currentPixel];

                        currentPixel += 1;
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
                        runningArray[getIndex(imageData[currentPixel])] = imageData[currentPixel];

                        currentPixel += 1;
                        i += 5;
                    },
                    else => {
                        const bitFlag: u8 = buffer[i] >> 6;
                        const data: u8 = buffer[i] & 0b00111111;
                        switch (bitFlag) {
                            QOI_OP_INDEX => {
                                imageData[currentPixel] = .{
                                    runningArray[data][0],
                                    runningArray[data][1],
                                    runningArray[data][2],
                                    runningArray[data][3],
                                };

                                prevPixel = imageData[currentPixel];

                                currentPixel += 1;
                                i += 1;
                            },
                            QOI_OP_DIFF => {
                                const rDiff: u8 = data >> 4;
                                const gDiff: u8 = (data & 0b001100) >> 2;
                                const bDiff: u8 = data & 0b000011;

                                if (rDiff < 3) {
                                    prevPixel[0] -%= 2 - 1 * rDiff;
                                } else {
                                    prevPixel[0] +%= 1;
                                }

                                if (gDiff < 3) {
                                    prevPixel[1] -%= 2 - 1 * gDiff;
                                } else {
                                    prevPixel[1] +%= 1;
                                }

                                if (bDiff < 3) {
                                    prevPixel[2] -%= 2 - 1 * bDiff;
                                } else {
                                    prevPixel[2] +%= 1;
                                }

                                imageData[currentPixel] = prevPixel;
                                runningArray[getIndex(imageData[currentPixel])] = imageData[currentPixel];

                                currentPixel += 1;
                                i += 1;
                            },
                            QOI_OP_LUMA => {
                                const rDiff: u8 = (buffer[i + 1] >> 4);
                                const bDiff: u8 = (buffer[i + 1] & 0b00001111);

                                if (rDiff <= 8) {
                                    prevPixel[0] -%= 8 - 1 * rDiff;
                                    if (data <= 32) {
                                        prevPixel[0] -%= 32 - 1 * data;
                                    } else {
                                        prevPixel[0] +%= data - 32;
                                    }
                                } else {
                                    prevPixel[0] +%= rDiff - 8;
                                    if (data <= 32) {
                                        prevPixel[0] -%= 32 - 1 * data;
                                    } else {
                                        prevPixel[0] +%= data - 32;
                                    }
                                }

                                if (data <= 32) {
                                    prevPixel[1] -%= 32 - 1 * data;
                                } else {
                                    prevPixel[1] +%= data - 32;
                                }

                                if (bDiff <= 8) {
                                    prevPixel[2] -%= 8 - 1 * bDiff;
                                    if (data <= 32) {
                                        prevPixel[2] -%= 32 - 1 * data;
                                    } else {
                                        prevPixel[2] +%= data - 32;
                                    }
                                } else {
                                    prevPixel[2] +%= bDiff - 8;
                                    if (data <= 32) {
                                        prevPixel[2] -%= 32 - 1 * data;
                                    } else {
                                        prevPixel[2] +%= data - 32;
                                    }
                                }

                                imageData[currentPixel] = prevPixel;
                                runningArray[getIndex(imageData[currentPixel])] = imageData[currentPixel];

                                currentPixel += 1;
                                i += 2;
                            },
                            QOI_OP_RUN => {
                                runLength = data + 1;
                                i += 1;
                            },
                        }
                    },
                }
            }
        }

        //Using up the remaining run length
        while (runLength > 0) {
            imageData[currentPixel] = prevPixel;
            currentPixel += 1;
            runLength -= 1;
        }

        return imageData;
    }
};

const FileEncoder = struct {
    pub fn encode(imageData: []u8, width: u32, height: u32, datasChannels: Channels, colorspace: Colorspace, allocator: std.mem.Allocator) []u8 {
        //worst case
        var encodeData: []u8 = switch (datasChannels) {
            .RGB => try allocator.alloc([]u8, width * height * QOI_OP_RGB_SIZE + QOI_HEADER_SIZE + QOI_END_MARKER),
            .RGBA => try allocator.alloc([]u8, width * height * QOI_OP_RGBA_SIZE + QOI_HEADER_SIZE + QOI_END_MARKER),
        };

        //QOI HEARDER
        const header: [14]u8 = std.mem.toBytes(qoi_header{
            .magic = "qoif",
            .width = @byteSwap(width),
            .height = @byteSwap(height),
            .channels = switch (datasChannels) {
                .RGB => 3,
                .RGBA => 4,
            },
            .colorspace = switch (colorspace) {
                .sRGB => 0,
                .LINEAR => 1,
            },
        });

        for (0..header.len) |i| {
            encodeData[i] = header[i];
        }

        var runLength: u8 = 0;

        switch (datasChannels) {
            .RGB => {
                var lastInstruction: QOI_OP_INSTRUCTIONS = QOI_OP_INSTRUCTIONS.QOI_OP_RGB;
                const runningArray: [][3]u8 = try allocator.alloc([3]u8, 64);
                for (0..runningArray.len) |i| {
                    runningArray[i] = .{
                        0,
                        0,
                        0,
                    };
                }

                var prevPixel: [3]u8 = .{
                    0,
                    0,
                    0,
                };

                var currentEncodedByte: u64 = 0;
                var i: u64 = 0;
                while (i < imageData.len) : (i += 3) {
                    if (prevPixel[0] == imageData[i] and
                        prevPixel[1] == imageData[i + 1] and
                        prevPixel[2] == imageData[i + 2])
                    {
                        if (runLength == 62) {
                            encodeData[currentEncodedByte] = runLength | QOI_OP_RUN;
                            currentEncodedByte += 1;
                            runLength = 0;
                        } else {
                            runLength += 1;
                        }
                    } else {
                        if (lastInstruction == QOI_OP_INSTRUCTIONS.QOI_OP_RUN) {
                            encodeData[i] = runLength | QOI_OP_RUN;
                            currentEncodedByte += 1;
                            runLength = 0;
                        }
                        //QOI_OP_INDEX
                        const pixel: []u8 = .{ imageData[i], imageData[i + 1], imageData[i + 2], 255 };
                        const currentRunningArray = runningArray[getIndex(pixel)];
                        if (currentRunningArray[0] == imageData[i] and
                            currentRunningArray[1] == imageData[i + 1] and
                            currentRunningArray[2] == imageData[i + 2])
                        {
                            encodeData[currentEncodedByte] = getIndex(pixel) | QOI_OP_INDEX;
                            currentEncodedByte += 1;
                        }
                        //QOI_OP_DIFF
                        //
                        //QOI_OP_LUMA
                        //
                        //QOI_OP_RGB

                        prevPixel = imageData[i..3];
                    }
                }
            },
            .RGBA => {
                const runningArray: [][4]u8 = try allocator.alloc([4]u8, 64);
                for (0..runningArray.len) |i| {
                    runningArray[i] = .{
                        0,
                        0,
                        0,
                        255,
                    };
                }

                var prevPixel: [4]u8 = .{
                    0,
                    0,
                    0,
                    255,
                };
                var lastInstruction: QOI_OP_INSTRUCTIONS = QOI_OP_INSTRUCTIONS.QOI_OP_RGBA;
                var i: u64 = 0;
                while (i < imageData.len) : (i += 4) {}
            },
        }

        return encodeData;
    }
};

fn getIndex(color: [4]u8) u8 {
    const r: u32 = color[0];
    const g: u32 = color[1];
    const b: u32 = color[2];
    const a: u32 = color[3];
    return @intCast((r * 3 + g * 5 + b * 7 + a * 11) % 64);
}
