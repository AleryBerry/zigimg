const std = @import("std");
pub const Error = std.mem.Allocator.Error;

const color = @import("../color.zig");
const Image = @import("../Image.zig");
const PixelFormatConverter = @import("../PixelFormatConverter.zig");

/// Flip the image vertically, along the X axis.
pub fn flipVertically(pixels: *const color.PixelStorage, height: usize, allocator: std.mem.Allocator) Error!void {
    var image_data = pixels.asBytes();
    const row_size = image_data.len / height;

    const temp = try allocator.alloc(u8, row_size);
    defer allocator.free(temp);
    while (image_data.len > row_size) : (image_data = image_data[row_size..(image_data.len - row_size)]) {
        const row1_data = image_data[0..row_size];
        const row2_data = image_data[image_data.len - row_size .. image_data.len];
        @memcpy(temp, row1_data);
        @memcpy(row1_data, row2_data);
        @memcpy(row2_data, temp);
    }
}

/// Create and allocate a cropped subsection of this image.
pub fn crop(image: *const Image, allocator: std.mem.Allocator, crop_area: Box) Error!Image {
    const box = crop_area.clamp(image.width, image.height);

    var cropped_pixels = try color.PixelStorage.init(
        allocator,
        image.pixelFormat(),
        box.width * box.height,
    );

    if (image.pixelFormat().isIndexed()) {
        const source_palette = image.pixels.getPalette().?;
        cropped_pixels.resizePalette(source_palette.len);

        const destination_palette = cropped_pixels.getPalette().?;

        @memcpy(destination_palette, source_palette);
    }

    if (box.width == 0 or box.height == 0 or
        image.width == 0 or image.height == 0)
    {
        return Image{
            .width = box.width,
            .height = box.height,
            .pixels = cropped_pixels,
        };
    }

    const original_data = image.pixels.asBytes();
    const cropped_data = cropped_pixels.asBytes();
    const pixel_size = image.pixelFormat().pixelStride();
    std.debug.assert(cropped_data.len == box.width * box.height * pixel_size);

    var y: usize = 0;
    const row_byte_width = box.width * pixel_size;
    while (y < box.height) : (y += 1) {
        const start_pixel = (box.x * pixel_size) + ((y + box.y) * image.width * pixel_size);
        const source = original_data[start_pixel .. start_pixel + row_byte_width];
        const destination_pixel = y * row_byte_width;
        const destination = cropped_data[destination_pixel .. destination_pixel + row_byte_width];
        @memcpy(destination, source);
    }

    return Image{
        .width = box.width,
        .height = box.height,
        .pixels = cropped_pixels,
    };
}

pub fn resize(image: *const Image, allocator: std.mem.Allocator, new_width: usize, new_height: usize) Error!Image {
    const old_width = image.width;
    const old_height = image.height;
    const original_format = image.pixelFormat();

    if (new_width == old_width and new_height == old_height) {
        return image.clone(allocator);
    }

    // 1. Convert source image to f32 for processing
    var float_pixels = try PixelFormatConverter.convert(allocator, &image.pixels, .float32);
    defer float_pixels.deinit(allocator);

    // 2. Pre-process: Convert to linear color and premultiply alpha
    var pre_processed_pixels = try color.PixelStorage.init(allocator, .float32, float_pixels.len());
    defer pre_processed_pixels.deinit(allocator);
    for (float_pixels.float32, 0..) |p, i| {
        pre_processed_pixels.float32[i] = .{ 
            .r = srgbToLinear(p.r) * p.a,
            .g = srgbToLinear(p.g) * p.a,
            .b = srgbToLinear(p.b) * p.a,
            .a = p.a,
        };
    }

    // 3. Allocate destination f32 pixel storage
    var resized_interpolated_pixels = try color.PixelStorage.init(allocator, .float32, new_width * new_height);
    defer resized_interpolated_pixels.deinit(allocator);

    // 4. Perform bilinear interpolation on linear, premultiplied data
    const original_data = pre_processed_pixels.float32;
    const resized_data = resized_interpolated_pixels.float32;

    var y: usize = 0;
    while (y < new_height) : (y += 1) {
        var x: usize = 0;
        while (x < new_width) : (x += 1) {
            const gx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(new_width)) * @as(f32, @floatFromInt(old_width));
            const gy: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(new_height)) * @as(f32, @floatFromInt(old_height));

            const gxi: usize = @intFromFloat(gx);
            const gyi: usize = @intFromFloat(gy);

            const xf: f32 = gx - @as(f32, @floatFromInt(gxi));
            const yf: f32 = gy - @as(f32, @floatFromInt(gyi));

            const x2: usize = @min(gxi + 1, old_width - 1);
            const y2: usize = @min(gyi + 1, old_height - 1);

            const p1 = original_data[gyi * old_width + gxi];
            const p2 = original_data[gyi * old_width + x2];
            const p3 = original_data[y2 * old_width + gxi];
            const p4 = original_data[y2 * old_width + x2];

            var interpolated_pixel: color.Colorf32 = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const p1c = p1.slice()[i];
                const p2c = p2.slice()[i];
                const p3c = p3.slice()[i];
                const p4c = p4.slice()[i];

                interpolated_pixel.slice()[i] =
                    p1c * (1 - xf) * (1 - yf) +
                    p2c * xf * (1 - yf) +
                    p3c * (1 - xf) * yf +
                    p4c * xf * yf;
            }

            resized_data[y * new_width + x] = interpolated_pixel;
        }
    }

    // 5. Post-process: Un-premultiply alpha and convert back to sRGB
    var post_processed_pixels = try color.PixelStorage.init(allocator, .float32, resized_interpolated_pixels.len());
    defer post_processed_pixels.deinit(allocator);
    for (resized_interpolated_pixels.float32, 0..) |p, i| {
        const alpha = if (p.a > 1e-6) p.a else 1.0;
        post_processed_pixels.float32[i] = .{
            .r = linearToSrgb(p.r / alpha),
            .g = linearToSrgb(p.g / alpha),
            .b = linearToSrgb(p.b / alpha),
            .a = p.a,
        };
    }

    // 6. Convert resized f32 data back to the original format
    const final_pixels = try PixelFormatConverter.convert(allocator, &post_processed_pixels, original_format);

    return Image{
        .width = new_width,
        .height = new_height,
        .pixels = final_pixels,
    };
}

// sRGB <-> linear conversion helpers
fn srgbToLinear(s: f32) f32 {
    if (s <= 0.04045) {
        return s / 12.92;
    }
    return std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(l: f32) f32 {
    if (l <= 0.0031308) {
        return l * 12.92;
    }
    return 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
}

/// A box describes the region of an image to be extracted. The crop
/// box should be a subsection of the original image.
///
/// If any of the parameters fall outside of the physical dimensions
/// of the image, the parameters can be normalised. For example, if
/// it is attempted to crop an area wider then the source image, the
/// `width` will be normalised to the physical width of the image.
pub const Box = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,

    /// If the crop area falls partially outside the image boundary,
    /// adjust the crop region.
    pub fn clamp(area: Box, image_width: usize, image_height: usize) Box {
        var box = area;
        if (box.x + box.width > image_width) box.width = image_width - box.x;
        if (box.y + box.height > image_height) box.height = image_height - box.y;
        return box;
    }
};
