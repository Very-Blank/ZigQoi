const std = @import("std");

pub const ChannelType = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const ColorSpaceType = enum(u8) {
    sRGB = 0, //sRGB with linear alpha
    linear = 1, //all channels linear
};

const RED_OFFSET = 0;
const GREEN_OFFSET = 1;
const BLUE_OFFSET = 2;
const ALPHA_OFFSET = 3;

pub const Header = struct {
    width: u32,
    height: u32,
    channels: ChannelType,
    colorSpace: ColorSpaceType,

    pub inline fn @"sizeOf(header)"() u64 {
        comptime var sum = 0;
        inline for (@typeInfo(Header).@"struct".fields) |field| {
            sum += @sizeOf(field.type);
        }

        return sum;
    }
};

const @"8BitFlagType" = enum(u8) {
    rgb = 0b11111110,
    rgba = 0b11111111,

    pub inline fn @"sizeOf(flag+data)"(@"enum": @"8BitFlagType") u64 {
        switch (@"enum") {
            .rgb => return @sizeOf(@"8BitFlagType") + @sizeOf([3]u8),
            .rgba => return @sizeOf(@"8BitFlagType") + @sizeOf([4]u8),
        }
    }

    pub inline fn sizeOfData(@"enum": @"8BitFlagType") u64 {
        switch (@"enum") {
            .rgb => @sizeOf([3]u8),
            .rgba => @sizeOf([4]u8),
        }
    }
};

const @"2BitFlagType" = enum(u2) {
    index = 0b00,
    diff = 0b01,
    luma = 0b10,
    run = 0b11,

    pub inline fn @"sizeOf(flag+data)"(@"enum": @"2BitFlagType") u64 {
        switch (@"enum") {
            .index => return (@bitSizeOf(@"2BitFlagType") + @bitSizeOf(u6)) / @bitSizeOf(u8),
            .diff => return (@bitSizeOf(@"2BitFlagType") + @bitSizeOf(u6)) / @bitSizeOf(u8),
            .luma => return (@bitSizeOf(@"2BitFlagType") + @bitSizeOf(u6) + @bitSizeOf(u8)) / @bitSizeOf(u8),
            .run => return (@bitSizeOf(@"2BitFlagType") + @bitSizeOf(u6)) / @bitSizeOf(u8),
        }
    }
};

const Luma = struct {
    const RED_MIN_ABS = 8;
    const GREEN_MIN_ABS = 32;
    const BLUE_MIN_ABS = 8;
};

const Diff = struct {
    const MIN_DIFF_ABS = 2;
    const MAX_DIFF = 1;
};

const END_MARKER = ([_]u8{0} ** 7) ++ [_]u8{1};

const Coder = struct {
    runningArray: [64][4]u8,
    previousPixel: [4]u8,
    index: u64,
    currentPixel: u64,
    runLength: u8,

    const init: Coder = Coder{
        .runningArray = [_][4]u8{[4]u8{ 0, 0, 0, 0 }} ** 64,
        .previousPixel = .{
            0,
            0,
            0,
            255,
        },
        .index = 0,
        .currentPixel = 0,
        .runLength = 0,
    };
};

const DecoderStatesType = enum {
    fullFlag,
    smallFlag,
    runFlag,
};

pub fn decode(buffer: []const u8, allocator: std.mem.Allocator) !struct { []u8, Header } {
    if (!std.mem.eql(u8, buffer[0..4], "qoif")) return error.InvalidMagicBytes;
    if (!std.mem.eql(u8, buffer[buffer.len - END_MARKER.len .. buffer.len], &END_MARKER)) return error.InvalidEndMarker;

    const header: Header = Header{
        .width = @byteSwap(std.mem.bytesToValue(u32, buffer[4..8])),
        .height = @byteSwap(std.mem.bytesToValue(u32, buffer[8..12])),
        .channels = switch (buffer[12]) {
            @intFromEnum(ChannelType.rgb) => ChannelType.rgb,
            @intFromEnum(ChannelType.rgba) => ChannelType.rgba,
            else => return error.InvalidQoiChannel,
        },
        .colorSpace = switch (buffer[13]) {
            @intFromEnum(ColorSpaceType.sRGB) => ColorSpaceType.sRGB,
            @intFromEnum(ColorSpaceType.linear) => ColorSpaceType.linear,
            else => return error.InvalidQoiColorSpace,
        },
    };

    const imageData: [][4]u8 = try allocator.alloc([4]u8, header.width * header.height);
    const imageBytes = buffer["qoif".len + Header.@"sizeOf(header)"() .. buffer.len - END_MARKER.len];

    var coder: Coder = .init;

    state: switch (DecoderStatesType.fullFlag) {
        .runFlag => {
            imageData[coder.currentPixel] = coder.previousPixel;

            coder.currentPixel += 1;
            coder.runLength -= 1;

            if (coder.runLength > 0 and coder.currentPixel < imageData.len) continue :state .runFlag;
            if (coder.index < imageBytes.len and coder.currentPixel < imageData.len) continue :state .fullFlag;
            break :state;
        },
        .fullFlag => {
            switch (imageBytes[coder.index]) {
                @intFromEnum(@"8BitFlagType".rgb) => {
                    if (imageBytes.len < coder.index + @"8BitFlagType".rgb.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @"8BitFlagType".flagSize();

                    imageData[coder.currentPixel] = .{
                        imageBytes[coder.index + RED_OFFSET],
                        imageBytes[coder.index + GREEN_OFFSET],
                        imageBytes[coder.index + BLUE_OFFSET],
                        coder.previousPixel[ALPHA_OFFSET],
                    };

                    coder.previousPixel = imageData[coder.currentPixel];
                    coder.runningArray[getIndex(imageData[coder.currentPixel])] = imageData[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"8BitFlagType".rgb.sizeOfData();

                    if (coder.index < imageBytes.len and coder.currentPixel < imageData.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"8BitFlagType".rgba) => {
                    if (imageBytes.len < coder.index + @"8BitFlagType".rgba.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @"8BitFlagType".flagSize();

                    imageData[coder.currentPixel] = .{
                        imageBytes[coder.index + RED_OFFSET],
                        imageBytes[coder.index + GREEN_OFFSET],
                        imageBytes[coder.index + BLUE_OFFSET],
                        imageBytes[coder.index + ALPHA_OFFSET],
                    };

                    coder.previousPixel = imageData[coder.currentPixel];
                    coder.runningArray[getIndex(imageData[coder.currentPixel])] = imageData[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"8BitFlagType".rgba.sizeOfData();

                    if (coder.index < imageBytes.len and coder.currentPixel < imageData.len) continue :state .fullFlag;
                    break :state;
                },
                else => continue :state .smallFlag,
            }
        },
        .smallFlag => {
            const data: u8 = imageBytes[coder.index] & 0b00111111;
            switch (@as(u2, @intCast((imageBytes[coder.index] & 0b11000000) >> 6))) {
                @intFromEnum(@"2BitFlagType".index) => {
                    imageData[coder.currentPixel] = .{
                        coder.runningArray[data][RED_OFFSET],
                        coder.runningArray[data][GREEN_OFFSET],
                        coder.runningArray[data][BLUE_OFFSET],
                        coder.runningArray[data][ALPHA_OFFSET],
                    };

                    coder.previousPixel = imageData[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".index.@"sizeOf(flag+data)"();

                    if (coder.index < imageBytes.len and coder.currentPixel < imageData.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".diff) => {
                    const rDiff: u8 = data >> 4;
                    const gDiff: u8 = (data & 0b001100) >> 2;
                    const bDiff: u8 = data & 0b000011;

                    if (rDiff < 3) {
                        coder.previousPixel[RED_OFFSET] -%= Diff.MIN_DIFF_ABS - rDiff;
                    } else {
                        coder.previousPixel[RED_OFFSET] +%= Diff.MAX_DIFF;
                    }

                    if (gDiff < 3) {
                        coder.previousPixel[GREEN_OFFSET] -%= Diff.MIN_DIFF_ABS - gDiff;
                    } else {
                        coder.previousPixel[GREEN_OFFSET] +%= Diff.MAX_DIFF;
                    }

                    if (bDiff < 3) {
                        coder.previousPixel[BLUE_OFFSET] -%= Diff.MIN_DIFF_ABS - bDiff;
                    } else {
                        coder.previousPixel[BLUE_OFFSET] +%= Diff.MAX_DIFF;
                    }

                    imageData[coder.currentPixel] = coder.previousPixel;
                    coder.runningArray[getIndex(imageData[coder.currentPixel])] = imageData[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".diff.@"sizeOf(flag+data)"();

                    if (coder.index < imageBytes.len and coder.currentPixel < imageData.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".luma) => {
                    if (imageBytes.len < coder.index + @"2BitFlagType".luma.@"sizeOf(flag+data)"()) return error.DataMissing;
                    const rDiff: u8 = (imageBytes[coder.index + 1] >> 4);
                    const bDiff: u8 = (imageBytes[coder.index + 1] & 0b00001111);

                    if (rDiff <= Luma.RED_MIN_ABS) {
                        coder.previousPixel[RED_OFFSET] -%= Luma.GREEN_MIN_ABS - rDiff;
                    } else {
                        coder.previousPixel[RED_OFFSET] +%= rDiff - Luma.RED_MIN_ABS;
                    }

                    if (data <= Luma.GREEN_MIN_ABS) {
                        coder.previousPixel[RED_OFFSET] -%= Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel[GREEN_OFFSET] -%= Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel[BLUE_OFFSET] -%= Luma.GREEN_MIN_ABS - data;
                    } else {
                        coder.previousPixel[RED_OFFSET] +%= data - Luma.GREEN_MIN_ABS;
                        coder.previousPixel[GREEN_OFFSET] +%= data - Luma.GREEN_MIN_ABS;
                        coder.previousPixel[BLUE_OFFSET] +%= data - Luma.GREEN_MIN_ABS;
                    }

                    if (bDiff <= Luma.BLUE_MIN_ABS) {
                        coder.previousPixel[BLUE_OFFSET] -%= Luma.BLUE_MIN_ABS - bDiff;
                    } else {
                        coder.previousPixel[BLUE_OFFSET] +%= bDiff - Luma.BLUE_MIN_ABS;
                    }

                    imageData[coder.currentPixel] = coder.previousPixel;
                    coder.runningArray[getIndex(imageData[coder.currentPixel])] = imageData[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".luma.@"sizeOf(flag+data)"();

                    if (coder.index < imageBytes.len and coder.currentPixel < imageData.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".run) => {
                    coder.runLength = data + 1;
                    coder.index += @"2BitFlagType".run.@"sizeOf(flag+data)"();

                    continue :state .runFlag;
                },
            }
        },
    }

    return .{ @ptrCast(imageData), header };
}

const EncodeStateType = enum {
    run,
    index,
    diff,
    luma,
    rgb,
    rgba,
};

pub fn encode(imageData: []u8, header: Header, allocator: std.mem.Allocator) ![]u8 {
    var buffer: []u8 = try allocator.alloc(u8, @as(u64, @intCast(header.width)) * @as(u64, @intCast(header.height)) * @as(u64, @intCast(
        switch (header.channels) {
            .rgb => @"8BitFlagType".rgb.@"sizeOf(flag+data)"(),
            .rgba => @"8BitFlagType".rgba.@"sizeOf(flag+data)"(),
        },
    )) + Header.@"sizeOf(header)"() + END_MARKER.len);

    errdefer allocator.free(buffer);

    //QOI HEARDER
    std.mem.copyForwards(u8, buffer[0..4], "qoif");
    std.mem.copyForwards(u8, buffer[4..8], &std.mem.toBytes(@byteSwap(header.width)));
    std.mem.copyForwards(u8, buffer[8..12], &std.mem.toBytes(@byteSwap(header.height)));

    buffer[12] = @intFromEnum(header.channels);
    buffer[13] = @intFromEnum(header.colorSpace);

    var coder: Coder = .init;
    state: switch (EncodeStateType.run) {
        .run => {
            if (coder.previousPixel[RED_OFFSET] != imageData[coder.currentPixel + RED_OFFSET] or
                coder.previousPixel[GREEN_OFFSET] != imageData[coder.currentPixel + GREEN_OFFSET] or
                coder.previousPixel[BLUE_OFFSET] != imageData[coder.currentPixel + BLUE_OFFSET] or
                (header.channels == .rgba and coder.previousPixel[ALPHA_OFFSET] != imageData[coder.currentPixel + ALPHA_OFFSET]))
            {
                if (coder.runLength > 0) {
                    buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.runLength;
                    coder.index = @"2BitFlagType".@"sizeOf(flag+data)"();
                }

                continue :state .index;
            }

            if (coder.runLength == 62) {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.runLength;
                coder.index = @"2BitFlagType".@"sizeOf(flag+data)"();
                coder.runLength = 0;
            } else {
                coder.runLength += 1;
            }

            continue :state .run;
        },
        .index => {
            const runningArrayPixel = coder.runningArray[
                getIndex(.{
                    imageData[coder.currentPixel + RED_OFFSET],
                    imageData[coder.currentPixel + GREEN_OFFSET],
                    imageData[coder.currentPixel + BLUE_OFFSET],
                    if (header.channels == .rgb) coder.previousPixel[ALPHA_OFFSET] else imageData[coder.currentPixel + ALPHA_OFFSET],
                })
            ];

            if (runningArrayPixel[RED_OFFSET] == imageData[coder.index + RED_OFFSET] and
                runningArrayPixel[GREEN_OFFSET] == imageData[coder.index + GREEN_OFFSET] and
                runningArrayPixel[BLUE_OFFSET] == imageData[coder.index + BLUE_OFFSET] and
                (header.channels == .rgb or (runningArrayPixel[ALPHA_OFFSET] == imageData[coder.currentPixel + ALPHA_OFFSET])))
            {
                buffer[coder.index] = runningArrayPixel;
                coder.index += 1;

                coder.previousPixel = imageData[coder.currentPixel + RED_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + GREEN_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + BLUE_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + ALPHA_OFFSET];

                continue :state .run;
            }

            if (header.channels == .rgba and coder.previousPixel[ALPHA_OFFSET] != imageData[coder.currentPixel + ALPHA_OFFSET]) continue :state .rgba;

            continue :state .diff;
        },
        .diff => {
            //
        },
        .luma => {
            //
        },
        .rgb => {
            //
        },
        .rgba => {
            //
        },
    }

    while (i < imageData.len) : (i += addAmmount) {
        if (datasChannels == Channels.RGB or datasChannels == Channels.RGBA and prevPixel[3] == imageData[i + 3]) {
            if (prevPixel[0] == imageData[i] and
                prevPixel[1] == imageData[i + 1] and
                prevPixel[2] == imageData[i + 2])
            {
                if (runLength == 62) {
                    buffer[currentEncodedByte] = QOI_OP_RUN | runLength;
                    currentEncodedByte += 1;
                    runLength = 0;
                } else if (run) {
                    runLength += 1;
                } else {
                    run = true;
                }
            } else {
                if (run) {
                    buffer[currentEncodedByte] = QOI_OP_RUN | runLength;
                    currentEncodedByte += 1;
                    runLength = 0;
                    run = false;
                }

                //QOI_OP_INDEX
                {
                    const currentRunningArray = runningArray[getIndex(imageData[coder.currentPixel + RED_OFFSET], imageData[i + GREEN_OFFSET], imageData[i + BLUE_OFFSET], prevPixel[3])];
                    if (currentRunningArray[0] == imageData[i] and
                        currentRunningArray[1] == imageData[i + 1] and
                        currentRunningArray[2] == imageData[i + 2])
                    {
                        buffer[currentEncodedByte] = getIndex(.{
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
                        buffer[currentEncodedByte] = QOI_OP_DIFF | (@as(u8, @intCast(rDifference)) << 4) | (@as(u8, @intCast(gDifference)) << 2) | @as(u8, @intCast(bDifference));
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
                        buffer[currentEncodedByte] = QOI_OP_LUMA | @as(u8, @intCast(gG));
                        currentEncodedByte += 1;
                        buffer[currentEncodedByte] = (@as(u8, @intCast(rG)) << 4) | @as(u8, @intCast(bG));
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
                buffer[currentEncodedByte] = QOI_OP_RGB;
                currentEncodedByte += 1;
                buffer[currentEncodedByte] = imageData[i];
                currentEncodedByte += 1;
                buffer[currentEncodedByte] = imageData[i + 1];
                currentEncodedByte += 1;
                buffer[currentEncodedByte] = imageData[i + 2];
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
                buffer[currentEncodedByte] = QOI_OP_RUN | runLength;
                currentEncodedByte += 1;
                runLength = 0;
                run = false;
            }

            //QOI_OP_RGBA
            buffer[currentEncodedByte] = QOI_OP_RGBA;
            currentEncodedByte += 1;
            buffer[currentEncodedByte] = imageData[i];
            currentEncodedByte += 1;
            buffer[currentEncodedByte] = imageData[i + 1];
            currentEncodedByte += 1;
            buffer[currentEncodedByte] = imageData[i + 2];
            currentEncodedByte += 1;
            buffer[currentEncodedByte] = imageData[i + 3];
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
        buffer[currentEncodedByte] = QOI_OP_RUN | runLength;
        currentEncodedByte += 1;
    }

    for (0..QOI_END_MARKER.len) |i| {
        buffer[currentEncodedByte] = QOI_END_MARKER[i];
        currentEncodedByte += 1;
    }

    if (currentEncodedByte < buffer.len) {
        const shortened = try allocator.alloc(u8, currentEncodedByte);
        for (0..currentEncodedByte) |i| {
            shortened[i] = buffer[i];
        }

        allocator.free(buffer);
        return shortened;
    }

    return buffer;
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

inline fn getIndex(red: u8, green: u8, blue: u8, alpha: u8) u8 {
    return @intCast((@as(u32, @intCast(red)) * 3 + @as(u32, @intCast(green)) * 5 + @as(u32, @intCast(blue)) * 7 + @as(u32, @intCast(alpha)) * 11) % 64);
}
