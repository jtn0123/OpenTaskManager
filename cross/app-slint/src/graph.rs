//! Graph lines as SVG path commands in the graph's own logical pixels, the
//! newest reading at the right edge. (Slint keeps a path's aspect ratio, so a
//! fixed viewbox would squeeze the graph; the window reports its size instead.)
//! A missing reading breaks the line; it's never drawn as zero.

use std::fmt::Write;

const ROWS: u32 = 4;
/// A vertical rule every this many samples, moving with the data.
const COLUMN_EVERY: i64 = 10;
/// Path commands that draw nothing: an empty string isn't a path.
pub const NOTHING: &str = "M 0 0";

/// A graph's size in logical pixels and the samples it spans.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub width: f64,
    pub height: f64,
    pub span: usize,
}

impl Frame {
    fn step(self) -> f64 {
        self.width / (self.span.max(2) - 1) as f64
    }

    fn x(self, age: usize) -> f64 {
        self.width - age as f64 * self.step()
    }

    fn y(self, value: f64, top: f64) -> f64 {
        self.height - 1.0 - (value / top).clamp(0.0, 1.0) * (self.height - 2.0)
    }
}

/// A point's age (0 = newest) and position.
type Point = (usize, f64, f64);

/// Runs of readings, oldest first, broken wherever one is missing.
fn runs(values: &[Option<f64>], top: f64, frame: Frame) -> Vec<Vec<Point>> {
    let top = if top.is_finite() && top > 0.0 { top } else { 1.0 };
    let count = values.len().min(frame.span);
    let mut runs = Vec::new();
    let mut run = Vec::new();
    for (index, value) in values[values.len() - count..].iter().enumerate() {
        let age = count - 1 - index;
        match value.filter(|value| value.is_finite()) {
            Some(value) => run.push((age, frame.x(age), frame.y(value, top))),
            None if !run.is_empty() => runs.push(std::mem::take(&mut run)),
            None => {}
        }
    }
    if !run.is_empty() {
        runs.push(run);
    }
    runs
}

fn finish(path: String) -> String {
    if path.is_empty() { NOTHING.to_owned() } else { path }
}

/// The line through the readings; a lone reading is a short dash, so it shows.
pub fn line(values: &[Option<f64>], top: f64, frame: Frame) -> String {
    let mut path = String::new();
    for run in runs(values, top, frame) {
        for (index, &(_, x, y)) in run.iter().enumerate() {
            let _ = write!(path, "{}{x:.1} {y:.1} ", if index == 0 { "M " } else { "L " });
        }
        if let [(_, x, y)] = run[..] {
            let _ = write!(path, "L {:.1} {y:.1} ", x - 2.0);
        }
    }
    finish(path)
}

/// The area under the line, closed down to the axis.
pub fn area(values: &[Option<f64>], top: f64, frame: Frame) -> String {
    let mut path = String::new();
    for run in runs(values, top, frame) {
        let (Some(&(_, first, _)), Some(&(_, last, _))) = (run.first(), run.last()) else { continue };
        if run.len() < 2 {
            continue;
        }
        let _ = write!(path, "M {first:.1} {:.1} ", frame.height);
        for &(_, x, y) in &run {
            let _ = write!(path, "L {x:.1} {y:.1} ");
        }
        let _ = write!(path, "L {last:.1} {:.1} Z ", frame.height);
    }
    finish(path)
}

/// Every other segment of the line, so a second line on the same graph never
/// differs by colour alone. Dashes follow the sample number, so they scroll
/// with the data instead of shimmering.
pub fn dashed(values: &[Option<f64>], top: f64, frame: Frame, samples: u64) -> String {
    let mut path = String::new();
    for run in runs(values, top, frame) {
        for pair in run.windows(2) {
            let [(age, x1, y1), (_, x2, y2)] = [pair[0], pair[1]];
            if (samples as i64 - age as i64).rem_euclid(2) == 0 {
                let _ = write!(path, "M {x1:.1} {y1:.1} L {x2:.1} {y2:.1} ");
            }
        }
    }
    finish(path)
}

/// Fixed rows, and columns every ten samples that move with the data.
pub fn grid(frame: Frame, samples: u64) -> String {
    let mut path = String::new();
    for row in 1..ROWS {
        let y = (frame.height * f64::from(row) / f64::from(ROWS)).round() + 0.5;
        let _ = write!(path, "M 0 {y:.1} L {:.1} {y:.1} ", frame.width);
    }
    for age in 0..frame.span {
        if (samples as i64 - age as i64).rem_euclid(COLUMN_EVERY) == 0 {
            let x = frame.x(age).round() - 0.5;
            let _ = write!(path, "M {x:.1} 0 L {x:.1} {:.1} ", frame.height);
        }
    }
    finish(path)
}

#[cfg(test)]
mod tests {
    use super::{Frame, NOTHING, area, dashed, grid, line};

    const FRAME: Frame = Frame { width: 236.0, height: 100.0, span: 60 };

    #[test]
    fn places_the_newest_reading_at_the_right_edge() {
        assert_eq!(line(&[Some(0.0), Some(100.0)], 100.0, FRAME), "M 232.0 99.0 L 236.0 1.0 ");
        assert_eq!(line(&[Some(250.0)], 100.0, FRAME), "M 236.0 1.0 L 234.0 1.0 ", "clamped, and a lone point shows");
    }

    #[test]
    fn a_missing_reading_breaks_the_line_and_the_area() {
        let values = [Some(10.0), Some(20.0), None, Some(30.0), Some(40.0)];
        let path = line(&values, 100.0, FRAME);
        assert_eq!(path.matches('M').count(), 2, "two runs: {path}");
        assert_eq!(area(&values, 100.0, FRAME).matches('Z').count(), 2);
        assert_eq!(line(&[None, None], 100.0, FRAME), NOTHING);
        assert_eq!(area(&[Some(5.0)], 100.0, FRAME), NOTHING, "one point has no area");
    }

    #[test]
    fn keeps_only_the_newest_span_and_spans_the_whole_width() {
        let values: Vec<Option<f64>> = (0..100).map(|value| Some(f64::from(value))).collect();
        let path = line(&values, 100.0, FRAME);
        assert_eq!(path.matches('L').count(), 59);
        assert!(path.starts_with("M 0.0 "), "the oldest visible reading is at the left edge: {path}");
    }

    #[test]
    fn dashes_and_grid_columns_move_with_the_samples() {
        let values = [Some(1.0), Some(2.0), Some(3.0)];
        assert_ne!(dashed(&values, 10.0, FRAME, 7), dashed(&values, 10.0, FRAME, 8));
        assert_eq!(dashed(&values, 10.0, FRAME, 7).matches('M').count(), 1);
        assert!(grid(FRAME, 10).contains("M 235.5 0 L 235.5 100.0"), "a column at the newest sample on a tenth");
        assert!(!grid(FRAME, 11).contains("M 235.5 0"));
    }
}
