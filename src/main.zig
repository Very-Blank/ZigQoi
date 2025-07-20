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
            if (@field(pixel1, field.name) != @field(pixel2, field.name)) {
                return false;
            }
        }

        return true;
    }
};

pub const Body = packed struct {
    pub const MAGIC_NUMBER: [4]u8 = .{ 'q', 'o', 'i', 'f' };
    width: u32,
    height: u32,
    channels: ChannelType,
    colorSpace: ColorSpaceType,
    pub const HEADER_SIZE: u64 = MAGIC_NUMBER.len + @sizeOf(u32) * 2 + @sizeOf(ChannelType) + @sizeOf(ColorSpaceType);

    pub const ChannelType = enum(u8) {
        rgb = 3,
        rgba = 4,
    };

    pub const ColorSpaceType = enum(u8) {
        sRGB = 0, //sRGB with linear alpha
        linear = 1, //all channels linear
    };

    pub const END_MARKER: [8]u8 = ([_]u8{0} ** 7) ++ [_]u8{1};
};

const @"8BitFlagType" = enum(u8) {
    rgb = 0b11111110,
    rgba = 0b11111111,

    pub inline fn @"sizeOf(flag+data)"(@"enum": @"8BitFlagType") u64 {
        switch (@"enum") {
            .rgb => return @sizeOf(@"8BitFlagType") + @sizeOf(struct { r: u8, g: u8, b: u8 }),
            .rgba => return @sizeOf(@"8BitFlagType") + @sizeOf(Pixel),
        }
    }

    pub inline fn sizeOfData(@"enum": @"8BitFlagType") u64 {
        return switch (@"enum") {
            .rgb => @sizeOf(struct { r: u8, g: u8, b: u8 }),
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
};

const Coder = struct {
    runningArray: [64]Pixel,
    previousPixel: Pixel,
    index: u64,
    currentPixelIndex: u64,
    run: u8,

    pub const RunLength = struct {
        const MAX_LENGTH = 62;
        const BIAS = 1;
    };

    const init: Coder = Coder{
        .runningArray = [_]Pixel{.zero} ** 64,
        .previousPixel = .init,
        .index = 0,
        .currentPixelIndex = 0,
        .run = 0,
    };
};

const DecoderStatesType = enum {
    fullFlag,
    smallFlag,
    runFlag,
};

pub fn decode(buffer: []const u8, allocator: std.mem.Allocator) !struct { []Pixel, Body } {
    if (buffer.len < Body.HEADER_SIZE + @"2BitFlagType".run.@"sizeOf(flag+data)"() + Body.END_MARKER.len) return error.InvalidFileLength;
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
    const encodedBytes = buffer[Body.HEADER_SIZE .. buffer.len - Body.END_MARKER.len];

    var coder: Coder = .init;

    state: switch (DecoderStatesType.fullFlag) {
        .runFlag => {
            pixels[coder.currentPixelIndex] = coder.previousPixel;

            coder.currentPixelIndex += 1;
            coder.run -= 1;

            if (coder.run > 0 and coder.currentPixelIndex < pixels.len) continue :state .runFlag;
            if (coder.index < encodedBytes.len and coder.currentPixelIndex < pixels.len) continue :state .fullFlag;
            break :state;
        },
        .fullFlag => {
            switch (encodedBytes[coder.index]) {
                @intFromEnum(@"8BitFlagType".rgb) => {
                    if (encodedBytes.len < coder.index + @"8BitFlagType".rgb.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @sizeOf(@"8BitFlagType");

                    pixels[coder.currentPixelIndex] = Pixel{
                        .red = encodedBytes[coder.index + @offsetOf(Pixel, "red")],
                        .green = encodedBytes[coder.index + @offsetOf(Pixel, "green")],
                        .blue = encodedBytes[coder.index + @offsetOf(Pixel, "blue")],
                        .alpha = coder.previousPixel.alpha,
                    };

                    coder.previousPixel = pixels[coder.currentPixelIndex];
                    coder.runningArray[getIndex(pixels[coder.currentPixelIndex])] = pixels[coder.currentPixelIndex];

                    coder.currentPixelIndex += 1;
                    coder.index += @"8BitFlagType".rgb.sizeOfData();

                    if (coder.index < encodedBytes.len and coder.currentPixelIndex < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"8BitFlagType".rgba) => {
                    if (encodedBytes.len < coder.index + @"8BitFlagType".rgba.@"sizeOf(flag+data)"()) return error.DataMissing;
                    coder.index += @sizeOf(@"8BitFlagType");

                    pixels[coder.currentPixelIndex] = Pixel{
                        .red = encodedBytes[coder.index + @offsetOf(Pixel, "red")],
                        .green = encodedBytes[coder.index + @offsetOf(Pixel, "green")],
                        .blue = encodedBytes[coder.index + @offsetOf(Pixel, "blue")],
                        .alpha = encodedBytes[coder.index + @offsetOf(Pixel, "alpha")],
                    };

                    coder.previousPixel = pixels[coder.currentPixelIndex];
                    coder.runningArray[getIndex(pixels[coder.currentPixelIndex])] = pixels[coder.currentPixelIndex];

                    coder.currentPixelIndex += 1;
                    coder.index += @"8BitFlagType".rgba.sizeOfData();

                    if (coder.index < encodedBytes.len and coder.currentPixelIndex < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                else => continue :state .smallFlag,
            }
        },
        .smallFlag => {
            const data: u8 = encodedBytes[coder.index] & 0b00111111;
            switch (@as(u2, @intCast((encodedBytes[coder.index] & 0b11000000) >> 6))) {
                @intFromEnum(@"2BitFlagType".index) => {
                    pixels[coder.currentPixelIndex] = coder.runningArray[data];

                    coder.previousPixel = pixels[coder.currentPixelIndex];

                    coder.currentPixelIndex += 1;
                    coder.index += @"2BitFlagType".index.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixelIndex < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".diff) => {
                    const rDiff: u8 = data >> 4;
                    const gDiff: u8 = (data & 0b001100) >> 2;
                    const bDiff: u8 = data & 0b000011;

                    if (rDiff < 3) {
                        coder.previousPixel.red -%= @"2BitFlagType".Diff.MIN_DIFF_ABS - rDiff;
                    } else {
                        coder.previousPixel.red +%= @"2BitFlagType".Diff.MAX_DIFF;
                    }

                    if (gDiff < 3) {
                        coder.previousPixel.green -%= @"2BitFlagType".Diff.MIN_DIFF_ABS - gDiff;
                    } else {
                        coder.previousPixel.green +%= @"2BitFlagType".Diff.MAX_DIFF;
                    }

                    if (bDiff < 3) {
                        coder.previousPixel.blue -%= @"2BitFlagType".Diff.MIN_DIFF_ABS - bDiff;
                    } else {
                        coder.previousPixel.blue +%= @"2BitFlagType".Diff.MAX_DIFF;
                    }

                    pixels[coder.currentPixelIndex] = coder.previousPixel;
                    coder.runningArray[getIndex(pixels[coder.currentPixelIndex])] = pixels[coder.currentPixelIndex];

                    coder.currentPixelIndex += 1;
                    coder.index += @"2BitFlagType".diff.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixelIndex < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".luma) => {
                    if (encodedBytes.len < coder.index + @"2BitFlagType".luma.@"sizeOf(flag+data)"()) return error.DataMissing;
                    const rDiff: u8 = (encodedBytes[coder.index + 1] >> 4);
                    const bDiff: u8 = (encodedBytes[coder.index + 1] & 0b00001111);

                    if (rDiff <= @"2BitFlagType".Luma.RED_MIN_ABS) {
                        coder.previousPixel.red -%= @"2BitFlagType".Luma.GREEN_MIN_ABS - rDiff;
                    } else {
                        coder.previousPixel.red +%= rDiff - @"2BitFlagType".Luma.RED_MIN_ABS;
                    }

                    if (data <= @"2BitFlagType".Luma.GREEN_MIN_ABS) {
                        coder.previousPixel.red -%= @"2BitFlagType".Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel.green -%= @"2BitFlagType".Luma.GREEN_MIN_ABS - data;
                        coder.previousPixel.blue -%= @"2BitFlagType".Luma.GREEN_MIN_ABS - data;
                    } else {
                        coder.previousPixel.red +%= data - @"2BitFlagType".Luma.GREEN_MIN_ABS;
                        coder.previousPixel.green +%= data - @"2BitFlagType".Luma.GREEN_MIN_ABS;
                        coder.previousPixel.blue +%= data - @"2BitFlagType".Luma.GREEN_MIN_ABS;
                    }

                    if (bDiff <= @"2BitFlagType".Luma.BLUE_MIN_ABS) {
                        coder.previousPixel.blue -%= @"2BitFlagType".Luma.BLUE_MIN_ABS - bDiff;
                    } else {
                        coder.previousPixel.blue +%= bDiff - @"2BitFlagType".Luma.BLUE_MIN_ABS;
                    }

                    pixels[coder.currentPixelIndex] = coder.previousPixel;
                    coder.runningArray[getIndex(pixels[coder.currentPixelIndex])] = pixels[coder.currentPixelIndex];

                    coder.currentPixelIndex += 1;
                    coder.index += @"2BitFlagType".luma.@"sizeOf(flag+data)"();

                    if (coder.index < encodedBytes.len and coder.currentPixelIndex < pixels.len) continue :state .fullFlag;
                    break :state;
                },
                @intFromEnum(@"2BitFlagType".run) => {
                    coder.run = data + Coder.RunLength.BIAS;
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

pub fn encode(pixels: []const u8, body: Body, allocator: std.mem.Allocator) ![]u8 {
    if (@as(u64, @intCast(body.width)) * @as(u64, @intCast(body.height)) * @intFromEnum(body.channels) != pixels.len) return error.InvalidPixels;

    var buffer: []u8 = try allocator.alloc(u8, @as(u64, @intCast(body.width)) * @as(u64, @intCast(body.height)) * @as(u64, @intCast(
        switch (body.channels) {
            .rgb => @"8BitFlagType".rgb.@"sizeOf(flag+data)"(),
            .rgba => @"8BitFlagType".rgba.@"sizeOf(flag+data)"(),
        },
    )) + Body.HEADER_SIZE + Body.END_MARKER.len);

    errdefer allocator.free(buffer);

    std.mem.copyForwards(u8, buffer[0..Body.MAGIC_NUMBER.len], &Body.MAGIC_NUMBER);
    std.mem.copyForwards(u8, buffer[Body.MAGIC_NUMBER.len .. Body.MAGIC_NUMBER.len + @sizeOf(u32)], &std.mem.toBytes(@byteSwap(body.width)));
    std.mem.copyForwards(u8, buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) .. Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2], &std.mem.toBytes(@byteSwap(body.height)));

    buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2] = @intFromEnum(body.channels);
    buffer[Body.MAGIC_NUMBER.len + @sizeOf(u32) * 2 + @sizeOf(Body.ChannelType)] = @intFromEnum(body.colorSpace);

    var coder: Coder = .init;
    coder.index = Body.HEADER_SIZE;

    var currentPixel: Pixel = .init;

    state: switch (EncodeStateType.run) {
        .bRun => {
            coder.runningArray[getIndex(currentPixel)] = currentPixel;
            coder.previousPixel = currentPixel;

            coder.currentPixelIndex += @intFromEnum(body.channels);

            if (coder.currentPixelIndex < pixels.len) continue :state .run;
            break :state;
        },
        .run => {
            currentPixel = Pixel{
                .red = pixels[coder.currentPixelIndex + @offsetOf(Pixel, "red")],
                .green = pixels[coder.currentPixelIndex + @offsetOf(Pixel, "green")],
                .blue = pixels[coder.currentPixelIndex + @offsetOf(Pixel, "blue")],
                .alpha = if (body.channels == .rgb) coder.previousPixel.alpha else pixels[coder.currentPixelIndex + @offsetOf(Pixel, "alpha")],
            };

            if (!Pixel.isEqual(coder.previousPixel, currentPixel)) {
                if (coder.run > 0) {
                    buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.run - Coder.RunLength.BIAS;
                    coder.index += @"2BitFlagType".run.@"sizeOf(flag+data)"();
                    coder.run = 0;
                }

                if (coder.currentPixelIndex < pixels.len) continue :state .index;
                break :state;
            }

            if (coder.run >= Coder.RunLength.MAX_LENGTH) {
                std.debug.assert(coder.run == Coder.RunLength.MAX_LENGTH);

                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.run - Coder.RunLength.BIAS;
                coder.index += @"2BitFlagType".run.@"sizeOf(flag+data)"();
                coder.run = 1;
            } else {
                coder.run += 1;
            }

            coder.currentPixelIndex += @intFromEnum(body.channels);

            if (coder.currentPixelIndex < pixels.len) {
                continue :state .run;
            } else if (coder.run > 0) {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".run)) << 6) | coder.run - Coder.RunLength.BIAS;
                coder.index += @"2BitFlagType".run.@"sizeOf(flag+data)"();
                coder.run = 0;
            }

            break :state;
        },
        .index => {
            const runningArrayPixel = coder.runningArray[getIndex(currentPixel)];

            if (Pixel.isEqual(currentPixel, runningArrayPixel)) {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".index)) << 6) | getIndex(currentPixel);
                coder.index += @"2BitFlagType".index.@"sizeOf(flag+data)"();

                coder.previousPixel = currentPixel;
                coder.currentPixelIndex += @intFromEnum(body.channels);

                if (coder.currentPixelIndex < pixels.len) continue :state .run;
                break :state;
            }

            if (coder.previousPixel.alpha != currentPixel.alpha) continue :state .rgba;

            continue :state .diff;
        },
        .diff => {
            const rDiff: i16 = @as(i16, @intCast(currentPixel.red)) - @as(i16, @intCast(coder.previousPixel.red)) + @"2BitFlagType".Diff.MIN_DIFF_ABS;
            const gDiff: i16 = @as(i16, @intCast(currentPixel.green)) - @as(i16, @intCast(coder.previousPixel.green)) + @"2BitFlagType".Diff.MIN_DIFF_ABS;
            const bDiff: i16 = @as(i16, @intCast(currentPixel.blue)) - @as(i16, @intCast(coder.previousPixel.blue)) + @"2BitFlagType".Diff.MIN_DIFF_ABS;

            if (0 <= rDiff and rDiff <= @"2BitFlagType".Diff.MAX_DIFF + @"2BitFlagType".Diff.MIN_DIFF_ABS and
                0 <= gDiff and gDiff <= @"2BitFlagType".Diff.MAX_DIFF + @"2BitFlagType".Diff.MIN_DIFF_ABS and
                0 <= bDiff and bDiff <= @"2BitFlagType".Diff.MAX_DIFF + @"2BitFlagType".Diff.MIN_DIFF_ABS)
            {
                buffer[coder.index] = (@as(u8, @intFromEnum(@"2BitFlagType".diff)) << 6) | (@as(u8, @intCast(rDiff)) << 4) | (@as(u8, @intCast(gDiff)) << 2) | @as(u8, @intCast(bDiff));

                coder.index += @"2BitFlagType".diff.@"sizeOf(flag+data)"();

                continue :state .bRun;
            }

            continue :state .luma;
        },
        .luma => {
            var gLuma: i16 = @as(i16, @intCast(currentPixel.red)) - @as(i16, @intCast(coder.previousPixel.green));
            const rLuma: i16 = @as(i16, @intCast(currentPixel.green)) - @as(i16, @intCast(coder.previousPixel.red)) - gLuma + @"2BitFlagType".Luma.RED_MIN_ABS;
            const bLuma: i16 = @as(i16, @intCast(currentPixel.blue)) - @as(i16, @intCast(coder.previousPixel.blue)) - gLuma + @"2BitFlagType".Luma.BLUE_MIN_ABS;
            gLuma += @"2BitFlagType".Luma.GREEN_MIN_ABS;

            if (0 <= rLuma and rLuma <= @"2BitFlagType".Luma.RED_MIN_ABS + @"2BitFlagType".Luma.BLUE_MAX and
                0 <= gLuma and gLuma <= @"2BitFlagType".Luma.GREEN_MIN_ABS + @"2BitFlagType".Luma.GREEN_MAX and
                0 <= bLuma and bLuma <= @"2BitFlagType".Luma.BLUE_MIN_ABS + @"2BitFlagType".Luma.BLUE_MAX)
            {
                buffer[coder.index] = (@as(u8, @intCast(@intFromEnum(@"2BitFlagType".luma))) << 6) | @as(u8, @intCast(gLuma));
                buffer[coder.index + @sizeOf(u8)] = (@as(u8, @intCast(rLuma)) << 4) | @as(u8, @intCast(gLuma));
                coder.index += @"2BitFlagType".luma.@"sizeOf(flag+data)"();

                continue :state .bRun;
            }

            continue :state .rgb;
        },
        .rgb => {
            buffer[coder.index] = @intFromEnum(@"8BitFlagType".rgb);
            buffer[coder.index + @sizeOf(@"8BitFlagType") + @offsetOf(Pixel, "red")] = currentPixel.red;
            buffer[coder.index + @sizeOf(@"8BitFlagType") + @offsetOf(Pixel, "green")] = currentPixel.green;
            buffer[coder.index + @sizeOf(@"8BitFlagType") + @offsetOf(Pixel, "blue")] = currentPixel.blue;
            coder.index += @"8BitFlagType".rgb.@"sizeOf(flag+data)"();

            continue :state .bRun;
        },
        .rgba => {
            buffer[coder.index] = @intFromEnum(@"8BitFlagType".rgba);
            inline for (@typeInfo(Pixel).@"struct".fields) |field| {
                buffer[coder.index + @sizeOf(@"8BitFlagType") + @offsetOf(Pixel, field.name)] = @field(currentPixel, field.name);
            }

            coder.index += @"8BitFlagType".rgba.@"sizeOf(flag+data)"();

            continue :state .bRun;
        },
    }

    if (coder.index + Body.END_MARKER.len < buffer.len) {
        const shortBuffer = try allocator.alloc(u8, coder.index + Body.END_MARKER.len);
        @memcpy(shortBuffer[0..coder.index], buffer[0..coder.index]);
        @memcpy(shortBuffer[coder.index .. coder.index + Body.END_MARKER.len], &Body.END_MARKER);
        allocator.free(buffer);

        return shortBuffer;
    }

    std.debug.assert(coder.index + Body.END_MARKER.len == buffer.len);

    @memcpy(buffer[coder.index .. coder.index + Body.END_MARKER.len], &Body.END_MARKER);

    return buffer;
}

inline fn getIndex(pixel: Pixel) u8 {
    return @intCast((@as(u32, @intCast(pixel.red)) * 3 + @as(u32, @intCast(pixel.green)) * 5 + @as(u32, @intCast(pixel.blue)) * 7 + @as(u32, @intCast(pixel.alpha)) * 11) % 64);
}
