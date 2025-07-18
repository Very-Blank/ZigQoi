const std = @import("std");

pub const Pixel = packed struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,

    const init: Pixel = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 };
    const zero: Pixel = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };

    pub fn isEqual(pixel1: Pixel, pixel2: Pixel) bool {
        inline for (@typeInfo(Pixel).@"struct".fields) |field| {
            if (@field(pixel1, field.name) != @field(pixel2, field.name)) return false;
        }

        return true;
    }
};

pub const Body = packed struct {
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
            .rgba => return @sizeOf(@"8BitFlagType") + @sizeOf(Pixel),
        }
    }

    pub inline fn sizeOfData(@"enum": @"8BitFlagType") u64 {
        return switch (@"enum") {
            .rgb => @sizeOf([3]u8),
            .rgba => @sizeOf(Pixel),
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
            .index => return @sizeOf(packed struct { flag: @"2BitFlagType", data: u6 }),
            .diff => return @sizeOf(packed struct { flag: @"2BitFlagType", data: u6 }),
            .luma => return @sizeOf(packed struct { flag: @"2BitFlagType", data1: u6, data2: u8 }),
            .run => return @sizeOf(packed struct { flag: @"2BitFlagType", data: u6 }),
        }
    }
};

const Luma = struct {
    const RED_MIN_ABS = 8;
    const GREEN_MIN_ABS = 32;
    const BLUE_MIN_ABS = 8;

    const RED_MAX = 7;
    const GREEN_MAX = 31;
    const BLUE_MAX = 7;
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
    runLength: RunLength,

    pub const RunLength = struct {
        len: u8,

        const MAX_LENGTH = 62;
        const BIAS = 1;

        const zero: RunLength = .{ .len = 0 };

        fn init(len: u8) RunLength {
            std.debug.assert(len <= MAX_LENGTH);
            return .{ .len = len + BIAS };
        }
    };

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
    if (!std.mem.eql(u8, buffer[0..Body.MAGIC_NUMBER.len], &Body.MAGIC_NUMBER)) return error.InvalidMagicBytes;
    if (!std.mem.eql(u8, buffer[buffer.len - Body.END_MARKER.len .. buffer.len], &Body.END_MARKER)) return error.InvalidEndMarker;

    const body: Body = Body{
        .width = @byteSwap(std.mem.bytesToValue(u32, buffer[Body.MAGIC_NUMBER.len .. Body.MAGIC_NUMBER.len + @sizeOf(u32)])),
        .height = @byteSwap(std.mem.bytesToValue(u32, buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) .. Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2])),
        .channels = switch (buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2]) {
            @intFromEnum(Body.ChannelType.rgb) => Body.ChannelType.rgb,
            @intFromEnum(Body.ChannelType.rgba) => Body.ChannelType.rgba,
            else => return error.InvalidQoiChannel,
        },
        .colorSpace = switch (buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2 + @sizeOf(Body.ChannelType)]) {
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
            coder.runLength.len -= 1;

            if (coder.runLength.len > 0 and coder.currentPixel < pixels.len) continue :state .runFlag;
            if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
            break :state;
        },
        .fullFlag => {
            switch (encodedBytes[coder.index]) {
                @intFromEnum(@"8BitFlagType".rgb) => {
                    if (encodedBytes.len < coder.index + @"8BitFlagType".rgb.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @sizeOf(@"8BitFlagType");

                    pixels[coder.currentPixel] = Pixel{
                        .red = encodedBytes[coder.index + @offsetOf(Pixel, "red")],
                        .green = encodedBytes[coder.index + @offsetOf(Pixel, "green")],
                        .blue = encodedBytes[coder.index + @offsetOf(Pixel, "blue")],
                        .alpha = coder.previousPixel.alpha,
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
                        .red = encodedBytes[coder.index + @offsetOf(Pixel, "red")],
                        .green = encodedBytes[coder.index + @offsetOf(Pixel, "green")],
                        .blue = encodedBytes[coder.index + @offsetOf(Pixel, "blue")],
                        .alpha = encodedBytes[coder.index + @offsetOf(Pixel, "alpha")],
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
                        coder.previousPixel.red -%= Diff.MIN_DIFF_ABS - rDiff;
                    } else {
                        coder.previousPixel.red +%= Diff.MAX_DIFF;
                    }

                    if (gDiff < 3) {
                        coder.previousPixel.green -%= Diff.MIN_DIFF_ABS - gDiff;
                    } else {
                        coder.previousPixel.green +%= Diff.MAX_DIFF;
                    }

                    if (bDiff < 3) {
                        coder.previousPixel.blue -%= Diff.MIN_DIFF_ABS - bDiff;
                    } else {
                        coder.previousPixel.blue +%= Diff.MAX_DIFF;
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
                        coder.previousPixel.red -%= Luma.GREEN_MIN_ABS - rDiff;
                    } else {
                        coder.previousPixel.red +%= rDiff - Luma.RED_MIN_ABS;
                    }

                    if (data <= Luma.GREEN_MIN_ABS) {
                        coder.previousPixel.red -%= Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel.green -%= Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel.blue -%= Luma.GREEN_MIN_ABS - data;
                    } else {
                        coder.previousPixel.red +%= data - Luma.GREEN_MIN_ABS;
                        coder.previousPixel.green +%= data - Luma.GREEN_MIN_ABS;
                        coder.previousPixel.blue +%= data - Luma.GREEN_MIN_ABS;
                    }

                    if (bDiff <= Luma.BLUE_MIN_ABS) {
                        coder.previousPixel.blue -%= Luma.BLUE_MIN_ABS - bDiff;
                    } else {
                        coder.previousPixel.blue +%= bDiff - Luma.BLUE_MIN_ABS;
                    }

                    pixels[coder.currentPixel] = coder.previousPixel;
                    coder.runningArray[getIndex(pixels[coder.currentPixel])] = pixels[coder.currentPixel];

                    coder.currentPixel += 1;
                    coder.index += @"2BitFlagType".luma.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixel < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".run) => {
                    coder.runLength = .init(data);
                    coder.index += @"2BitFlagType".run.@"sizeOf(flag+data)"();

                    continue :state .runFlag;
                },
            }
        },
    }

    return .{ pixels, body };
}

const EncodeStateType = enum {
    bRun,
    run,
    index,
    diff,
    luma,
    rgb,
    rgba,
};

pub fn encode(pixels: []u8, body: Body, allocator: std.mem.Allocator) ![]u8 {
    var buffer: []u8 = try allocator.alloc(u8, @as(u64, @intCast(body.width)) * @as(u64, @intCast(body.height)) * @as(u64, @intCast(
        switch (body.channels) {
            .rgb => @"8BitFlagType".rgb.@"sizeOf(flag+data)"(),
            .rgba => @"8BitFlagType".rgba.@"sizeOf(flag+data)"(),
        },
    )) + Body.@"sizeOf(header)"() + Body.END_MARKER.len);

    errdefer allocator.free(buffer);

    //QOI HEARDER
    std.mem.copyForwards(u8, buffer[0..Body.MAGIC_NUMBER.len], Body.MAGIC_NUMBER);
    std.mem.copyForwards(u8, buffer[Body.MAGIC_NUMBER.len .. Body.MAGIC_NUMBER.len + @sizeOf(u32)], &std.mem.toBytes(@byteSwap(body.width)));
    std.mem.copyForwards(u8, buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) .. Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2], &std.mem.toBytes(@byteSwap(body.height)));

    buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2] = @intFromEnum(body.channels);
    buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2 + @sizeOf(Body.ChannelType)] = @intFromEnum(body.colorSpace);

    var coder: Coder = .init;
    state: switch (EncodeStateType.run) {
        .bRun => {
            coder.runningArray[
                getIndex(Pixel{
                    .red = pixels[coder.currentPixel + @offsetOf(Pixel, "red")],
                    .green = pixels[coder.currentPixel + @offsetOf(Pixel, "green")],
                    .blue = pixels[coder.currentPixel + @offsetOf(Pixel, "blue")],
                    .alpha = coder.previousPixel.alpha,
                })
            ] = Pixel{
                .red = pixels[coder.currentPixel + @offsetOf(Pixel, "red")],
                .green = pixels[coder.currentPixel + @offsetOf(Pixel, "green")],
                .blue = pixels[coder.currentPixel + @offsetOf(Pixel, "blue")],
                .alpha = coder.previousPixel.alpha,
            };

            coder.previousPixel.red = pixels[coder.currentPixel + @offsetOf(Pixel, "red")];
            coder.previousPixel.green = pixels[coder.currentPixel + @offsetOf(Pixel, "green")];
            coder.previousPixel.blue = pixels[coder.currentPixel + @offsetOf(Pixel, "red")];

            if (body.channels == .rgba) {
                coder.previousPixel.blue = pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")];
            }

            coder.currentPixel += 1;
            continue :state .run;
        },
        .run => {
            if (coder.previousPixel.red != pixels[coder.currentPixel + @offsetOf(Pixel, "red")] or
                coder.previousPixel.green != pixels[coder.currentPixel + @offsetOf(Pixel, "green")] or
                coder.previousPixel.blue != pixels[coder.currentPixel + @offsetOf(Pixel, "blue")] or
                (body.channels == .rgba and coder.previousPixel.alpha != pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")]))
            {
                if (coder.runLength.len > 0) {
                    buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.runLength;
                    coder.index += @"2BitFlagType".@"sizeOf(flag+data)"();
                }

                continue :state .index;
            }

            if (coder.runLength.len == Coder.RunLength.MAX_LENGTH) {
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
                getIndex(Pixel{
                    .red = pixels[coder.currentPixel + @offsetOf(Pixel, "red")],
                    .blue = pixels[coder.currentPixel + @offsetOf(Pixel, "green")],
                    .green = pixels[coder.currentPixel + @offsetOf(Pixel, "blue")],
                    .alpha = if (body.channels == .rgb) coder.previousPixel.alpha else pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")],
                })
            ];

            if (runningArrayPixel.red == pixels[coder.index + @offsetOf(Pixel, "red")] and
                runningArrayPixel.green == pixels[coder.index + @offsetOf(Pixel, "green")] and
                runningArrayPixel.blue == pixels[coder.index + @offsetOf(Pixel, "blue")] and
                (body.channels == .rgb or (runningArrayPixel.alpha == pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")])))
            {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".index)) << 6) | getIndex(Pixel{
                    .red = pixels[coder.currentPixel + @offsetOf(Pixel, "red")],
                    .blue = pixels[coder.currentPixel + @offsetOf(Pixel, "green")],
                    .green = pixels[coder.currentPixel + @offsetOf(Pixel, "blue")],
                    .alpha = if (body.channels == .rgb) coder.previousPixel.alpha else pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")],
                });

                coder.index += @"2BitFlagType".index.@"sizeOf(flag+data)"();

                coder.previousPixel.red = pixels[coder.currentPixel + @offsetOf(Pixel, "red")];
                coder.previousPixel.green = pixels[coder.currentPixel + @offsetOf(Pixel, "green")];
                coder.previousPixel.blue = pixels[coder.currentPixel + @offsetOf(Pixel, "blue")];

                if (body.channels == .rgba) {
                    coder.previousPixel.blue = pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")];
                }

                coder.currentPixel += 1;

                continue :state .run;
            }

            if (body.channels == .rgba and coder.previousPixel.alpha != pixels[coder.currentPixel + @offsetOf(Pixel, "alpha")]) continue :state .rgba;

            continue :state .diff;
        },
        .diff => {
            const rDiff: i16 = @as(i16, @intCast(pixels[coder.currentPixel + @offsetOf(Pixel, "red")])) - @as(i16, @intCast(coder.previousPixel.red)) + Diff.MIN_DIFF_ABS;
            const gDiff: i16 = @as(i16, @intCast(pixels[coder.currentPixel + @offsetOf(Pixel, "green")])) - @as(i16, @intCast(coder.previousPixel.green)) + Diff.MIN_DIFF_ABS;
            const bDiff: i16 = @as(i16, @intCast(pixels[coder.currentPixel + @offsetOf(Pixel, "blue")])) - @as(i16, @intCast(coder.previousPixel.blue)) + Diff.MIN_DIFF_ABS;

            if (0 <= rDiff and rDiff <= Diff.MAX_DIFF + Diff.MIN_DIFF_ABS and
                0 <= gDiff and gDiff <= Diff.MAX_DIFF + Diff.MIN_DIFF_ABS and
                0 <= bDiff and bDiff <= Diff.MAX_DIFF + Diff.MIN_DIFF_ABS)
            {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".diff)) << 6) | (@as(u8, @intCast(rDiff)) << 4) | (@as(u8, @intCast(gDiff)) << 2) | @as(u8, @intCast(bDiff));

                coder.index += @"2BitFlagType".diff.@"sizeOf(flag+data)"();

                continue :state .bRun;
            }

            continue :state .luma;
        },
        .luma => {
            var gLuma: i16 = @as(i16, @intCast(pixels[coder.currentPixel + @offsetOf(Pixel, "green")])) - @as(i16, @intCast(coder.previousPixel.green));
            const rLuma: i16 = @as(i16, @intCast(pixels[coder.currentPixel + @offsetOf(Pixel, "red")])) - @as(i16, @intCast(coder.previousPixel.red)) - gLuma + Luma.RED_MIN_ABS;
            const bLuma: i16 = @as(i16, @intCast(pixels[coder.currentPixel + @offsetOf(Pixel, "blue")])) - @as(i16, @intCast(coder.previousPixel.blue)) - gLuma + Luma.BLUE_MIN_ABS;
            gLuma += Luma.GREEN_MIN_ABS;

            if (0 <= rLuma and rLuma <= Luma.RED_MIN_ABS + Luma.BLUE_MAX and
                0 <= gLuma and gLuma <= Luma.GREEN_MIN_ABS + Luma.GREEN_MAX and
                0 <= bLuma and bLuma <= Luma.BLUE_MIN_ABS + Luma.BLUE_MAX)
            {
                buffer[coder.index] = (@as(u8, @intCast(@"2BitFlagType".luma)) << 6) | @as(u8, @intCast(gLuma));
                coder.index += @sizeOf(u8);
                buffer[coder.index] = (@as(u8, @intCast(rLuma)) << 4) | @as(u8, @intCast(gLuma));
                coder.index += @sizeOf(u8);

                continue :state .bRun;
            }

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
    return @intCast((@as(u32, @intCast(pixel.red)) * 3 + @as(u32, @intCast(pixel.green)) * 5 + @as(u32, @intCast(pixel.blue)) * 7 + @as(u32, @intCast(pixel.alpha)) * 11) % 64);
}
