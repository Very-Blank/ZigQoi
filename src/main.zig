const std = @import("std");

pub const Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    const init: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const zero: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn isEqual(pixel1: Pixel, pixel2: Pixel) bool {
        inline for (@typeInfo(Pixel).@"struct".fields) |field| {
            if (@field(pixel1, field.name) != @field(pixel2, field.name)) return false;
        }

        return true;
    }
};

pub const Body = struct {
    width: u32,
    height: u32,
    channels: ChannelType,
    colorSpace: ColorSpaceType,

    pub const ChannelType = enum(u8) {
        rgb = 3,
        rgba = 4,
    };

    pub const ColorSpaceType = enum(u8) {
        sRGB = 0, //sRGB with linear alpha
        linear = 1, //all channels linear
    };

    pub const MAGIC_NUMBER: [4]u8 = .{ 'q', 'o', 'i', 'f' };
    pub const END_MARKER: [8]u8 = ([_]u8{0} ** 7) ++ [_]u8{1};

    pub inline fn @"sizeOf(header)"() u64 {
        comptime var sum = 0;
        inline for (@typeInfo(Body).@"struct".fields) |field| {
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
        return switch (@"enum") {
            .rgb => @sizeOf([3]u8),
            .rgba => @sizeOf([4]u8),
        };
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

const Coder = struct {
    runningArray: [64]Pixel,
    previousPixel: Pixel,
    index: u64,
    currentPixel: u64,
    runLength: u8,

    const init: Coder = Coder{
        .runningArray = [_]Pixel{.zero} ** 64,
        .previousPixel = .init,
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

pub fn decode(buffer: []const u8, allocator: std.mem.Allocator) !struct { []Pixel, Body } {
    if (!std.mem.eql(u8, buffer[0..4], &Body.MAGIC_NUMBER)) return error.InvalidMagicBytes;
    if (!std.mem.eql(u8, buffer[buffer.len - Body.END_MARKER.len .. buffer.len], &Body.END_MARKER)) return error.InvalidEndMarker;

    const body: Body = Body{
        .width = @byteSwap(std.mem.bytesToValue(u32, buffer[4..8])),
        .height = @byteSwap(std.mem.bytesToValue(u32, buffer[8..12])),
        .channels = switch (buffer[12]) {
            @intFromEnum(Body.ChannelType.rgb) => Body.ChannelType.rgb,
            @intFromEnum(Body.ChannelType.rgba) => Body.ChannelType.rgba,
            else => return error.InvalidQoiChannel,
        },
        .colorSpace = switch (buffer[13]) {
            @intFromEnum(Body.ColorSpaceType.sRGB) => Body.ColorSpaceType.sRGB,
            @intFromEnum(Body.ColorSpaceType.linear) => Body.ColorSpaceType.linear,
            else => return error.InvalidQoiColorSpace,
        },
    };

    const pixels: []Pixel = try allocator.alloc(Pixel, body.width * body.height);
    const encodedBytes = buffer[Body.MAGIC_NUMBER.len + Body.@"sizeOf(header)"() .. buffer.len - Body.END_MARKER.len];

    var coder: Coder = .init;

    state: switch (DecoderStatesType.fullFlag) {
        .runFlag => {
            pixels[coder.currentPixel] = coder.previousPixel;

            coder.currentPixel += 1;
            coder.runLength -= 1;

            if (coder.runLength > 0 and coder.currentPixel < pixels.len) continue :state .runFlag;
            if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
            break :state;
        },
        .fullFlag => {
            switch (encodedBytes[coder.index]) {
                @intFromEnum(@"8BitFlagType".rgb) => {
                    if (encodedBytes.len < coder.index + @"8BitFlagType".rgb.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @sizeOf(@"8BitFlagType");

                    pixels[coder.currentPixel] = Pixel{
                        .r = encodedBytes[coder.index + @offsetOf(Pixel, "r")],
                        .g = encodedBytes[coder.index + @offsetOf(Pixel, "g")],
                        .b = encodedBytes[coder.index + @offsetOf(Pixel, "b")],
                        .a = coder.previousPixel.a,
                    };

                    coder.previousPixel = pixels[coder.currentPixel];
                    coder.runningArray[getIndex(pixels[coder.currentPixel])] = pixels[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"8BitFlagType".rgb.sizeOfData();

                    if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"8BitFlagType".rgba) => {
                    if (encodedBytes.len < coder.index + @"8BitFlagType".rgba.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @sizeOf(@"8BitFlagType");

                    pixels[coder.currentPixel] = Pixel{
                        .r = encodedBytes[coder.index + @offsetOf(Pixel, "r")],
                        .g = encodedBytes[coder.index + @offsetOf(Pixel, "g")],
                        .b = encodedBytes[coder.index + @offsetOf(Pixel, "b")],
                        .a = encodedBytes[coder.index + @offsetOf(Pixel, "a")],
                    };

                    coder.previousPixel = pixels[coder.currentPixel];
                    coder.runningArray[getIndex(pixels[coder.currentPixel])] = pixels[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"8BitFlagType".rgba.sizeOfData();

                    if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                else => continue :state .smallFlag,
            }
        },
        .smallFlag => {
            const data: u8 = encodedBytes[coder.index] & 0b00111111;
            switch (@as(u2, @intCast((encodedBytes[coder.index] & 0b11000000) >> 6))) {
                @intFromEnum(@"2BitFlagType".index) => {
                    pixels[coder.currentPixel] = coder.runningArray[data];

                    coder.previousPixel = pixels[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".index.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".diff) => {
                    const rDiff: u8 = data >> 4;
                    const gDiff: u8 = (data & 0b001100) >> 2;
                    const bDiff: u8 = data & 0b000011;

                    if (rDiff < 3) {
                        coder.previousPixel.r -%= Diff.MIN_DIFF_ABS - rDiff;
                    } else {
                        coder.previousPixel.r +%= Diff.MAX_DIFF;
                    }

                    if (gDiff < 3) {
                        coder.previousPixel.g -%= Diff.MIN_DIFF_ABS - gDiff;
                    } else {
                        coder.previousPixel.g +%= Diff.MAX_DIFF;
                    }

                    if (bDiff < 3) {
                        coder.previousPixel.b -%= Diff.MIN_DIFF_ABS - bDiff;
                    } else {
                        coder.previousPixel.b +%= Diff.MAX_DIFF;
                    }

                    pixels[coder.currentPixel] = coder.previousPixel;
                    coder.runningArray[getIndex(pixels[coder.currentPixel])] = pixels[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".diff.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".luma) => {
                    if (encodedBytes.len < coder.index + @"2BitFlagType".luma.@"sizeOf(flag+data)"()) return error.DataMissing;
                    const rDiff: u8 = (encodedBytes[coder.index + 1] >> 4);
                    const bDiff: u8 = (encodedBytes[coder.index + 1] & 0b00001111);

                    if (rDiff <= Luma.RED_MIN_ABS) {
                        coder.previousPixel.r -%= Luma.GREEN_MIN_ABS - rDiff;
                    } else {
                        coder.previousPixel.r +%= rDiff - Luma.RED_MIN_ABS;
                    }

                    if (data <= Luma.GREEN_MIN_ABS) {
                        coder.previousPixel.r -%= Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel.g -%= Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel.b -%= Luma.GREEN_MIN_ABS - data;
                    } else {
                        coder.previousPixel.r +%= data - Luma.GREEN_MIN_ABS;
                        coder.previousPixel.g +%= data - Luma.GREEN_MIN_ABS;
                        coder.previousPixel.b +%= data - Luma.GREEN_MIN_ABS;
                    }

                    if (bDiff <= Luma.BLUE_MIN_ABS) {
                        coder.previousPixel.b -%= Luma.BLUE_MIN_ABS - bDiff;
                    } else {
                        coder.previousPixel.b +%= bDiff - Luma.BLUE_MIN_ABS;
                    }

                    pixels[coder.currentPixel] = coder.previousPixel;
                    coder.runningArray[getIndex(pixels[coder.currentPixel])] = pixels[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".luma.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
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

    return .{ pixels, body };
}

const EncodeStateType = enum {
    run,
    index,
    diff,
    luma,
    rgb,
    rgba,
};

pub fn encode(imageData: []u8, header: Body, allocator: std.mem.Allocator) ![]u8 {
    var buffer: []u8 = try allocator.alloc(u8, @as(u64, @intCast(header.width)) * @as(u64, @intCast(header.height)) * @as(u64, @intCast(
        switch (header.channels) {
            .rgb => @"8BitFlagType".rgb.@"sizeOf(flag+data)"(),
            .rgba => @"8BitFlagType".rgba.@"sizeOf(flag+data)"(),
        },
    )) + Body.@"sizeOf(header)"() + Body.END_MARKER.len);

    errdefer allocator.free(buffer);

    //QOI HEARDER
    std.mem.copyForwards(u8, buffer[0..4], Body.MAGIC_NUMBER);
    std.mem.copyForwards(u8, buffer[4..8], &std.mem.toBytes(@byteSwap(header.width)));
    std.mem.copyForwards(u8, buffer[8..12], &std.mem.toBytes(@byteSwap(header.height)));

    buffer[12] = @intFromEnum(header.channels);
    buffer[13] = @intFromEnum(header.colorSpace);

    var coder: Coder = .init;
    state: switch (EncodeStateType.run) {
        .run => {
            if (coder.previousPixel != imageData[coder.currentPixel + RED_OFFSET] or
                coder.previousPixel != imageData[coder.currentPixel + GREEN_OFFSET] or
                coder.previousPixel != imageData[coder.currentPixel + BLUE_OFFSET] or
                (header.channels == .rgba and coder.previousPixel[ALPHA_OFFSET] != imageData[coder.currentPixel + ALPHA_OFFSET]))
            {
                if (coder.runLength > 0) {
                    buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.runLength;
                    coder.index += @"2BitFlagType".@"sizeOf(flag+data)"();
                }

                continue :state .index;
            }

            if (coder.runLength == 62) {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.runLength;
                coder.index = @"2BitFlagType".run.@"sizeOf(flag+data)"();
                coder.runLength = 0;
            } else {
                coder.runLength += 1;
            }

            coder.currentPixel += 1;

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
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".index)) << 6) | getIndex(.{
                    imageData[coder.currentPixel + RED_OFFSET],
                    imageData[coder.currentPixel + GREEN_OFFSET],
                    imageData[coder.currentPixel + BLUE_OFFSET],
                    if (header.channels == .rgb) coder.previousPixel[ALPHA_OFFSET] else imageData[coder.currentPixel + ALPHA_OFFSET],
                });

                coder.index += @"2BitFlagType".index.@"sizeOf(flag+data)"();

                coder.previousPixel = imageData[coder.currentPixel + RED_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + GREEN_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + BLUE_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + ALPHA_OFFSET];

                coder.currentPixel += 1;

                continue :state .run;
            }

            if (header.channels == .rgba and coder.previousPixel[ALPHA_OFFSET] != imageData[coder.currentPixel + ALPHA_OFFSET]) continue :state .rgba;

            continue :state .diff;
        },
        .diff => {
            // 0 - 255 = 1
            const rDiff: i8 = @as(i8, @intCast(imageData[coder.currentPixel + RED_OFFSET])) - @as(i8, @intCast(coder.previousPixel[RED_OFFSET])) + Diff.MIN_DIFF_ABS;
            const gDiff: i8 = @as(i8, @intCast(imageData[coder.currentPixel + GREEN_OFFSET])) - @as(i8, @intCast(coder.previousPixel[GREEN_OFFSET])) + Diff.MIN_DIFF_ABS;
            const bDiff: i8 = @as(i8, @intCast(imageData[coder.currentPixel + BLUE_OFFSET])) - @as(i8, @intCast(coder.previousPixel[BLUE_OFFSET])) + Diff.MIN_DIFF_ABS;
            if (0 <= rDiff and rDiff <= Diff.MAX_DIFF + Diff.MIN_DIFF_ABS and
                0 <= gDiff and gDiff <= Diff.MAX_DIFF + Diff.MIN_DIFF_ABS and
                0 <= bDiff and bDiff <= Diff.MAX_DIFF + Diff.MIN_DIFF_ABS)
            {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".diff)) << 6) | (@as(u8, @intCast(rDiff)) << 4) | (@as(u8, @intCast(gDiff)) << 2) | @as(u8, @intCast(bDiff));

                coder.index += @"2BitFlagType".diff.@"sizeOf(flag+data)"();

                coder.runningArray[
                    getIndex(.{
                        imageData[coder.currentPixel + RED_OFFSET],
                        imageData[coder.currentPixel + RED_OFFSET],
                        imageData[coder.currentPixel + RED_OFFSET],
                        coder.previousPixel[ALPHA_OFFSET],
                    })
                ] = .{
                    imageData[coder.currentPixel + RED_OFFSET],
                    imageData[coder.currentPixel + GREEN_OFFSET],
                    imageData[coder.currentPixel + BLUE_OFFSET],
                    coder.previousPixel[ALPHA_OFFSET],
                };

                coder.previousPixel = imageData[coder.currentPixel + RED_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + GREEN_OFFSET];
                coder.previousPixel = imageData[coder.currentPixel + BLUE_OFFSET];

                coder.currentPixel += 1;

                continue :state .run;
            }

            continue :state .luma;
        },
        .luma => {
            // const gDiff: i8 = @as(i8, @intCast(imageData[coder.currentPixel + GREEN_OFFSET])) - @as(i8, @intCast(coder.previousPixel[GREEN_OFFSET]));
            // const rDiff: i8 = @as(i8, @intCast(imageData[coder.currentPixel + RED_OFFSET])) - @as(i8, @intCast(coder.previousPixel[RED_OFFSET])) - gDiff;
            // const bDiff: i8 = @as(i8, @intCast(imageData[coder.currentPixel + BLUE_OFFSET])) - @as(i8, @intCast(coder.previousPixel[BLUE_OFFSET])) - gDiff;

            continue :state .rgb;
        },
        .rgb => {
            continue :state .run;
        },
        .rgba => {
            continue :state .run;
        },
    }

    return buffer;
}

inline fn getIndex(pixel: Pixel) u8 {
    return @intCast((@as(u32, @intCast(pixel.r)) * 3 + @as(u32, @intCast(pixel.g)) * 5 + @as(u32, @intCast(pixel.b)) * 7 + @as(u32, @intCast(pixel.a)) * 11) % 64);
}
