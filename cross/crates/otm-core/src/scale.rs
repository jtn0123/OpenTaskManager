//! Axis tops for graphs of byte rates, whose range has no natural ceiling.

/// The smallest round step (1, 2 or 5 times a power of ten) at or above
/// `value`; 0 for zero, negative or non-finite values.
pub fn round_step(value: f64) -> f64 {
    if !value.is_finite() || value <= 0.0 {
        return 0.0;
    }
    let power = 10f64.powf(value.log10().floor());
    for factor in [1.0, 2.0, 5.0, 10.0] {
        let step = factor * power;
        // A relative margin, so 3.0000000001 doesn't round up because of how 3 was computed.
        if step >= value * (1.0 - 1e-12) {
            return step;
        }
    }
    10.0 * power
}

/// The smallest round byte count at or above `value` in the 1024-based units
/// the interface shows (1, 2, 5, 10 … 500 KB, then 1 MB), so an axis reads
/// "500 KB/s", never "488 KB/s". 1 byte at least; 0 for nothing to show.
pub fn round_bytes(value: f64) -> f64 {
    if !value.is_finite() || value <= 0.0 {
        return 0.0;
    }
    let mut unit = 1.0;
    while value >= unit * 1024.0 * (1.0 - 1e-12) {
        unit *= 1024.0;
    }
    let step = round_step((value / unit).max(1.0));
    // 1000 of a unit reads better as 1 of the next.
    if step >= 1000.0 { unit * 1024.0 } else { step * unit }
}

/// A rate graph's top value: the round byte count above the highest visible
/// point, raised at once, and lowered only after the data has stayed under
/// a smaller step for `patience` samples, so the axis doesn't jump with
/// every dip. Never below `floor`, so near-idle traffic isn't drawn full height.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AutoScale {
    bound: f64,
    floor: f64,
    patience: u32,
    low: u32,
}

impl AutoScale {
    pub fn new(floor: f64, patience: u32) -> Self {
        let floor = round_bytes(floor).max(1.0);
        Self { bound: floor, floor, patience, low: 0 }
    }

    pub fn bound(&self) -> f64 {
        self.bound
    }

    /// Takes the highest point now visible and returns the axis top.
    pub fn update(&mut self, visible_max: f64) -> f64 {
        let target = round_bytes(visible_max).max(self.floor);
        if target > self.bound {
            self.bound = target;
            self.low = 0;
        } else if target < self.bound {
            self.low += 1;
            if self.low >= self.patience {
                self.bound = target;
                self.low = 0;
            }
        } else {
            self.low = 0;
        }
        self.bound
    }
}

#[cfg(test)]
mod tests {
    use super::{AutoScale, round_bytes, round_step};

    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;

    #[test]
    fn rounds_up_to_one_two_or_five() {
        assert_eq!(round_step(0.0), 0.0);
        assert_eq!(round_step(-3.0), 0.0);
        assert_eq!(round_step(f64::NAN), 0.0);
        assert_eq!(round_step(1.0), 1.0);
        assert_eq!(round_step(1.2), 2.0);
        assert_eq!(round_step(3.0), 5.0);
        assert_eq!(round_step(7.0), 10.0);
        assert_eq!(round_step(10.0), 10.0);
        assert_eq!(round_step(1_500_000.0), 2_000_000.0);
        assert!((round_step(0.03) - 0.05).abs() < 1e-12);
    }

    #[test]
    fn rounds_bytes_in_the_units_they_are_shown_in() {
        assert_eq!(round_bytes(0.0), 0.0);
        assert_eq!(round_bytes(0.3), 1.0);
        assert_eq!(round_bytes(700.0), 1.0 * KB, "1000 bytes reads as 1 KB");
        assert_eq!(round_bytes(1.0 * KB), 1.0 * KB);
        assert_eq!(round_bytes(1.5 * KB), 2.0 * KB);
        assert_eq!(round_bytes(300.0 * KB), 500.0 * KB);
        assert_eq!(round_bytes(600.0 * KB), 1.0 * MB);
        assert_eq!(round_bytes(4.0 * MB), 5.0 * MB);
        assert_eq!(round_bytes(5_000_000.0), 5.0 * MB, "4.77 MB rounds to 5 MB");
    }

    #[test]
    fn grows_at_once_and_shrinks_only_after_patience() {
        let mut scale = AutoScale::new(1.0 * KB, 3);
        assert_eq!(scale.update(400.0), 1.0 * KB, "never below the floor");
        assert_eq!(scale.update(150.0 * KB), 200.0 * KB, "grows at once");
        assert_eq!(scale.update(9.0 * KB), 200.0 * KB);
        assert_eq!(scale.update(9.0 * KB), 200.0 * KB);
        assert_eq!(scale.update(9.0 * KB), 10.0 * KB, "shrinks on the third low sample");
    }

    #[test]
    fn a_spike_while_waiting_starts_the_wait_again() {
        let mut scale = AutoScale::new(1.0, 2);
        scale.update(100.0);
        scale.update(10.0);
        assert_eq!(scale.update(100.0), 100.0);
        assert_eq!(scale.update(10.0), 100.0, "the earlier low sample no longer counts");
        assert_eq!(scale.update(10.0), 10.0);
    }
}
