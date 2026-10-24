//! The tray icon: recent CPU load as bars, drawn into RGBA pixels.

/// Bar colour, then the dim frame that keeps an idle icon visible.
const BAR: [u8; 4] = [0x35, 0xd0, 0x7f, 0xff];
const FRAME: [u8; 4] = [0x80, 0x80, 0x80, 0xa0];

/// A `size` × `size` RGBA image (row-major, top row first) of `values`
/// (percent, 0–100) as two-pixel bars, newest on the right. Values past the
/// icon's width are the oldest and are left out; missing ones leave a gap.
pub fn cpu_bars(values: &[f32], size: u32) -> Vec<u8> {
    let size = size.max(4) as usize;
    let mut pixels = vec![0u8; size * size * 4];
    let mut put = |x: usize, y: usize, colour: [u8; 4]| {
        let at = (y * size + x) * 4;
        pixels[at..at + 4].copy_from_slice(&colour);
    };
    for i in 0..size {
        put(i, 0, FRAME);
        put(i, size - 1, FRAME);
        put(0, i, FRAME);
        put(size - 1, i, FRAME);
    }
    let inner = size - 2;
    let bars = inner / 2;
    for (slot, value) in values.iter().rev().take(bars).enumerate() {
        let value = if value.is_finite() { value.clamp(0.0, 100.0) } else { 0.0 };
        let height = ((value / 100.0) * inner as f32).ceil() as usize;
        let x = 1 + inner - 2 * (slot + 1);
        for y in (1 + inner - height)..(1 + inner) {
            put(x, y, BAR);
            put(x + 1, y, BAR);
        }
    }
    pixels
}

#[cfg(test)]
mod tests {
    use super::{BAR, FRAME, cpu_bars};

    fn pixel(image: &[u8], size: usize, x: usize, y: usize) -> [u8; 4] {
        let at = (y * size + x) * 4;
        image[at..at + 4].try_into().unwrap()
    }

    #[test]
    fn draws_the_newest_value_at_the_right() {
        let image = cpu_bars(&[0.0, 100.0], 32);
        assert_eq!(image.len(), 32 * 32 * 4);
        // The newest (100%) bar fills the two columns inside the right edge.
        for y in 1..31 {
            assert_eq!(pixel(&image, 32, 29, y), BAR);
            assert_eq!(pixel(&image, 32, 30, y), BAR);
        }
        // The older (0%) bar draws nothing.
        assert_eq!(pixel(&image, 32, 27, 30), [0, 0, 0, 0]);
        assert_eq!(pixel(&image, 32, 0, 0), FRAME);
    }

    #[test]
    fn a_small_load_still_shows_a_pixel_and_odd_values_are_clamped() {
        let image = cpu_bars(&[150.0, f32::NAN, 1.0], 16);
        assert_eq!(pixel(&image, 16, 13, 14), BAR, "1% rounds up to one pixel");
        assert_eq!(pixel(&image, 16, 11, 14), [0, 0, 0, 0], "NaN draws nothing");
        assert_eq!(pixel(&image, 16, 9, 1), BAR, "150% is drawn as full");
    }
}
