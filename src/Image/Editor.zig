const std = @import("std");
pub const Error = std.mem.Allocator.Error;

const color = @import("../color.zig");
const Image = @import("../Image.zig");

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

    const pixel_format = image.pixelFormat();
    const bytes_per_pixel = pixel_format.pixelStride();

    const original_data = image.pixels.asBytes();
    const resized_pixels = try color.PixelStorage.init(
        allocator,
        pixel_format,
        new_width * new_height,
    );
    const resized_data = resized_pixels.asBytes();

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

            var c: usize = 0;
            while (c < bytes_per_pixel) : (c += 1) {
                const p1_idx = (gyi * old_width + gxi) * bytes_per_pixel + c;
                const p2_idx = (gyi * old_width + x2) * bytes_per_pixel + c;
                const p3_idx = (y2 * old_width + gxi) * bytes_per_pixel + c;
                const p4_idx = (y2 * old_width + x2) * bytes_per_pixel + c;

                const p1: f32 = @floatFromInt(original_data[p1_idx]);
                const p2: f32 = @floatFromInt(original_data[p2_idx]);
                const p3: f32 = @floatFromInt(original_data[p3_idx]);
                const p4: f32 = @floatFromInt(original_data[p4_idx]);

                const interpolated_value: f32 =
                    p1 * (1 - xf) * (1 - yf) +
                    p2 * xf * (1 - yf) +
                    p3 * (1 - xf) * yf +
                    p4 * xf * yf;

                const dst_idx = (y * new_width + x) * bytes_per_pixel + c;
                resized_data[dst_idx] = @intFromFloat(@max(0.0, @min(255.0, interpolated_value)));
            }
        }
    }

    return Image{
        .width = new_width,
        .height = new_height,
        .pixels = resized_pixels,
    };
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
