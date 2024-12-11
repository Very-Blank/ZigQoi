const std = @import("std");

pub const Channels = enum {
    RGB,
    RGBA,
};

pub const Colorspace = enum {
    sRGB, //sRGB with linear alpha
    LINEAR, //all channels linear
};

// flags
const QOI_OP_RGB: u8 = 0b11111110;
const QOI_OP_RGBA: u8 = 0b11111111;
const QOI_OP_INDEX: u8 = 0b00000000;
const QOI_OP_DIFF: u8 = 0b01000000;
const QOI_OP_LUMA: u8 = 0b10000000;
const QOI_OP_RUN: u8 = 0b11000000;

const QOI_END_MARKER: [8]u8 = [_]u8{0} ** 8;
// (1 + 3) = tag + rgb
const QOI_OP_RGB_SIZE: u8 = 1 + 3;
// (1 + 4) = tag + rgba
const QOI_OP_RGBA_SIZE: u8 = 1 + 4;
const QOI_HEADER_SIZE = 14;

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
        defer allocator.free(buffer);
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

        fileDecoder.imageBinData = try decode(buffer[QOI_HEADER_SIZE .. buffer.len - QOI_END_MARKER.len], fileDecoder.header.width, fileDecoder.header.height, allocator);

        return fileDecoder;
    }

    pub fn deInit(self: *const FileDecoder) void {
        self.allocator.free(self.imageBinData);
    }

    pub fn decode(buffer: []u8, width: u32, height: u32, allocator: std.mem.Allocator) ![][4]u8 {
        const imageData: [][4]u8 = try allocator.alloc([4]u8, width * height);
        errdefer allocator.free(imageData);
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
            if (currentPixel >= imageData.len) {
                return error.PixelCountOverflow;
            }

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
                        const bitFlag: u8 = buffer[i] & 0b11000000;
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
                            else => return error.Unreachable,
                        }
                    },
                }
            }
        }

        //Using up the remaining run length
        while (runLength > 0) {
            if (currentPixel >= imageData.len) {
                return error.PixelCountOverflow;
            }

            imageData[currentPixel] = prevPixel;
            currentPixel += 1;
            runLength -= 1;
        }

        return imageData;
    }
};

pub const FileEncoder = struct {
    pub fn writeImageTofile(fileName: []const u8, imageData: []u8, width: u32, height: u32, datasChannels: Channels, colorspace: Colorspace, allocator: std.mem.Allocator) !void {
        const encodingData: []u8 = try encode(imageData, width, height, datasChannels, colorspace, allocator);
        defer allocator.free(encodingData);

        try std.fs.cwd().writeFile(std.fs.Dir.WriteFileOptions{
            .sub_path = fileName,
            .data = encodingData,
        });
    }

    pub fn encode(imageData: []u8, width: u32, height: u32, datasChannels: Channels, colorspace: Colorspace, allocator: std.mem.Allocator) ![]u8 {
        //worst case
        var encodeData: []u8 = switch (datasChannels) {
            .RGB => try allocator.alloc(u8, @as(u64, @intCast(width)) * @as(u64, @intCast(height)) * @as(u64, @intCast(QOI_OP_RGB_SIZE)) + QOI_HEADER_SIZE + QOI_END_MARKER.len),
            .RGBA => try allocator.alloc(u8, @as(u64, @intCast(width)) * @as(u64, @intCast(height)) * @as(u64, @intCast(QOI_OP_RGBA_SIZE)) + QOI_HEADER_SIZE + QOI_END_MARKER.len),
        };

        errdefer allocator.free(encodeData);

        var currentEncodedByte: u64 = 14;

        {
            //QOI HEARDER
            std.mem.copyForwards(u8, encodeData[0..4], "qoif");
            std.mem.copyForwards(u8, encodeData[4..8], &std.mem.toBytes(@byteSwap(width)));
            std.mem.copyForwards(u8, encodeData[8..12], &std.mem.toBytes(@byteSwap(height)));

            encodeData[12] = switch (datasChannels) {
                .RGB => 3,
                .RGBA => 4,
            };

            encodeData[13] = switch (colorspace) {
                .sRGB => 0,
                .LINEAR => 1,
            };

            const runningArray: [][4]u8 = try allocator.alloc([4]u8, 64);
            defer allocator.free(runningArray);

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

            var run: bool = false;
            var runLength: u8 = 0;

            var i: u64 = 0;
            const addAmmount: u8 = if (datasChannels == Channels.RGB) 3 else 4;
            while (i < imageData.len) : (i += addAmmount) {
                if (datasChannels == Channels.RGB or datasChannels == Channels.RGBA and prevPixel[3] == imageData[i + 3]) {
                    if (prevPixel[0] == imageData[i] and
                        prevPixel[1] == imageData[i + 1] and
                        prevPixel[2] == imageData[i + 2])
                    {
                        if (runLength == 62) {
                            encodeData[currentEncodedByte] = QOI_OP_RUN | runLength;
                            currentEncodedByte += 1;
                            runLength = 0;
                        } else if (run) {
                            runLength += 1;
                        } else {
                            run = true;
                        }
                    } else {
                        if (run) {
                            encodeData[currentEncodedByte] = QOI_OP_RUN | runLength;
                            currentEncodedByte += 1;
                            runLength = 0;
                            run = false;
                        }

                        //QOI_OP_INDEX
                        {
                            const currentRunningArray = runningArray[getIndex(.{ imageData[i], imageData[i + 1], imageData[i + 2], prevPixel[3] })];
                            if (currentRunningArray[0] == imageData[i] and
                                currentRunningArray[1] == imageData[i + 1] and
                                currentRunningArray[2] == imageData[i + 2])
                            {
                                encodeData[currentEncodedByte] = getIndex(.{
                                    imageData[i],
                                    imageData[i + 1],
                                    imageData[i + 2],
                                    prevPixel[3],
                                });

                                currentEncodedByte += 1;

                                prevPixel[0] = imageData[i];
                                prevPixel[1] = imageData[i + 1];
                                prevPixel[2] = imageData[i + 2];
                                continue;
                            }
                        }

                        //QOI_OP_DIFF
                        const rDiff: i16 = @as(i16, @intCast(imageData[i])) - @as(i16, @intCast(prevPixel[0]));
                        const gDiff: i16 = @as(i16, @intCast(imageData[i + 1])) - @as(i16, @intCast(prevPixel[1]));
                        const bDiff: i16 = @as(i16, @intCast(imageData[i + 2])) - @as(i16, @intCast(prevPixel[2]));

                        {
                            const rDifference = calculateDiff(rDiff, -2, 1);
                            const gDifference = calculateDiff(gDiff, -2, 1);
                            const bDifference = calculateDiff(bDiff, -2, 1);

                            if (0 <= rDifference and rDifference <= 3 and
                                0 <= gDifference and gDifference <= 3 and
                                0 <= bDifference and bDifference <= 3)
                            {
                                encodeData[currentEncodedByte] = QOI_OP_DIFF | (@as(u8, @intCast(rDifference)) << 4) | (@as(u8, @intCast(gDifference)) << 2) | @as(u8, @intCast(bDifference));
                                currentEncodedByte += 1;

                                runningArray[getIndex(.{ imageData[i], imageData[i + 1], imageData[i + 2], prevPixel[3] })] = .{
                                    imageData[i],
                                    imageData[i + 1],
                                    imageData[i + 2],
                                    prevPixel[3],
                                };

                                prevPixel[0] = imageData[i];
                                prevPixel[1] = imageData[i + 1];
                                prevPixel[2] = imageData[i + 2];
                                continue;
                            }
                        }

                        //QOI_OP_LUMA
                        {
                            const rG: i16 = calculateDiff(rDiff - gDiff, -8, 7);
                            const gG: i16 = calculateDiff(gDiff, -32, 31);
                            const bG: i16 = calculateDiff(bDiff - gDiff, -8, 7);

                            if (0 <= rG and rG <= 15 and
                                0 <= gG and gG <= 63 and
                                0 <= bG and bG <= 15)
                            {
                                encodeData[currentEncodedByte] = QOI_OP_LUMA | @as(u8, @intCast(gG));
                                currentEncodedByte += 1;
                                encodeData[currentEncodedByte] = (@as(u8, @intCast(rG)) << 4) | @as(u8, @intCast(bG));
                                currentEncodedByte += 1;

                                runningArray[getIndex(.{ imageData[i], imageData[i + 1], imageData[i + 2], prevPixel[3] })] = .{
                                    imageData[i],
                                    imageData[i + 1],
                                    imageData[i + 2],
                                    prevPixel[3],
                                };

                                prevPixel[0] = imageData[i];
                                prevPixel[1] = imageData[i + 1];
                                prevPixel[2] = imageData[i + 2];
                                continue;
                            }
                        }

                        //QOI_OP_RGB
                        encodeData[currentEncodedByte] = QOI_OP_RGB;
                        currentEncodedByte += 1;
                        encodeData[currentEncodedByte] = imageData[i];
                        currentEncodedByte += 1;
                        encodeData[currentEncodedByte] = imageData[i + 1];
                        currentEncodedByte += 1;
                        encodeData[currentEncodedByte] = imageData[i + 2];
                        currentEncodedByte += 1;

                        runningArray[getIndex(.{ imageData[i], imageData[i + 1], imageData[i + 2], prevPixel[3] })] = .{
                            imageData[i],
                            imageData[i + 1],
                            imageData[i + 2],
                            prevPixel[3],
                        };

                        prevPixel[0] = imageData[i];
                        prevPixel[1] = imageData[i + 1];
                        prevPixel[2] = imageData[i + 2];
                        continue;
                    }
                } else {
                    if (run) {
                        encodeData[currentEncodedByte] = QOI_OP_RUN | runLength;
                        currentEncodedByte += 1;
                        runLength = 0;
                        run = false;
                    }

                    //QOI_OP_RGBA
                    encodeData[currentEncodedByte] = QOI_OP_RGBA;
                    currentEncodedByte += 1;
                    encodeData[currentEncodedByte] = imageData[i];
                    currentEncodedByte += 1;
                    encodeData[currentEncodedByte] = imageData[i + 1];
                    currentEncodedByte += 1;
                    encodeData[currentEncodedByte] = imageData[i + 2];
                    currentEncodedByte += 1;
                    encodeData[currentEncodedByte] = imageData[i + 3];
                    currentEncodedByte += 1;

                    runningArray[getIndex(.{ imageData[i], imageData[i + 1], imageData[i + 2], imageData[i + 3] })] = .{
                        imageData[i],
                        imageData[i + 1],
                        imageData[i + 2],
                        imageData[i + 3],
                    };

                    prevPixel[0] = imageData[i];
                    prevPixel[1] = imageData[i + 1];
                    prevPixel[2] = imageData[i + 2];
                    prevPixel[3] = imageData[i + 3];
                    continue;
                }
            }

            if (run) {
                encodeData[currentEncodedByte] = QOI_OP_RUN | runLength;
                currentEncodedByte += 1;
            }
        }

        for (0..QOI_END_MARKER_SIZE) |i| {
            encodeData[currentEncodedByte] = QOI_END_MARKER[i];
            currentEncodedByte += 1;
        }

        if (currentEncodedByte < encodeData.len) {
            const shortened = try allocator.alloc(u8, currentEncodedByte);
            for (0..currentEncodedByte) |i| {
                shortened[i] = encodeData[i];
            }

            allocator.free(encodeData);
            return shortened;
        }

        return encodeData;
    }

    inline fn calculateDiff(diff: i16, minDiff: i16, maxDiff: i16) i16 {
        if (minDiff <= diff and diff <= maxDiff) {
            return diff + @abs(minDiff);
        } else if (diff - 254 <= maxDiff and 255 <= diff) {
            return diff - 254 + @abs(minDiff);
        } else if (diff + 254 >= minDiff and diff <= -255) {
            return diff + 254 + @abs(minDiff);
        }

        return -1;
    }
};

inline fn getIndex(color: [4]u8) u8 {
    const r: u32 = color[0];
    const g: u32 = color[1];
    const b: u32 = color[2];
    const a: u32 = color[3];
    return @intCast((r * 3 + g * 5 + b * 7 + a * 11) % 64);
}
