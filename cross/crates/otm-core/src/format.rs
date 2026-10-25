//! Figures as the native interfaces show them. A missing reading is "—", never zero.

pub const MISSING: &str = "—";

const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];

/// `value` in the largest 1024-based unit that keeps it at 1 or more.
fn in_units(value: f64) -> (f64, &'static str, bool) {
    let mut scaled = value;
    let mut index = 0;
    while scaled >= 1024.0 && index < UNITS.len() - 1 {
        scaled /= 1024.0;
        index += 1;
    }
    (scaled, UNITS[index], index == 0)
}

fn usable(value: Option<f64>) -> Option<f64> {
    value.filter(|value| value.is_finite() && *value >= 0.0)
}

/// Bytes in 1024 steps, as Windows and most Linux tools show them: three significant figures.
pub fn bytes(value: Option<f64>) -> String {
    let Some(value) = usable(value) else { return MISSING.to_owned() };
    let (scaled, unit, is_bytes) = in_units(value);
    let digits = if is_bytes || scaled >= 100.0 {
        0
    } else if scaled >= 10.0 {
        1
    } else {
        2
    };
    format!("{scaled:.digits$} {unit}")
}

pub fn rate(value: Option<f64>) -> String {
    match usable(value) {
        Some(value) => format!("{}/s", bytes(Some(value))),
        None => MISSING.to_owned(),
    }
}

/// An axis top, which is always round: no trailing zeros ("5 MB/s", "1.5 MB/s").
pub fn axis_rate(value: f64) -> String {
    let Some(value) = usable(Some(value)) else { return MISSING.to_owned() };
    let (scaled, unit, _) = in_units(value);
    let text = format!("{scaled:.2}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    format!("{text} {unit}/s")
}

/// One decimal under 10%, whole numbers above.
pub fn percent(value: Option<f64>) -> String {
    let Some(value) = value.filter(|value| value.is_finite()) else { return MISSING.to_owned() };
    let value = value.max(0.0);
    if value < 10.0 { format!("{value:.1}%") } else { format!("{value:.0}%") }
}

/// How long something has run, to two units at most: "45 s", "12 min",
/// "3 h 12 min", "2 d 4 h".
pub fn duration(seconds: u64) -> String {
    let (minutes, hours, days) = (seconds / 60, seconds / 3600, seconds / 86_400);
    if days > 0 {
        format!("{days} d {} h", hours % 24)
    } else if hours > 0 {
        format!("{hours} h {} min", minutes % 60)
    } else if minutes > 0 {
        format!("{minutes} min")
    } else {
        format!("{seconds} s")
    }
}

#[cfg(test)]
mod tests {
    use super::{MISSING, axis_rate, bytes, percent, rate};

    #[test]
    fn durations_keep_two_units_at_most() {
        use super::duration;
        assert_eq!(duration(45), "45 s");
        assert_eq!(duration(12 * 60 + 59), "12 min");
        assert_eq!(duration(3 * 3600 + 12 * 60 + 5), "3 h 12 min");
        assert_eq!(duration(2 * 86_400 + 4 * 3600 + 30 * 60), "2 d 4 h");
    }

    #[test]
    fn missing_figures_are_a_dash_never_zero() {
        assert_eq!(bytes(None), MISSING);
        assert_eq!(rate(None), MISSING);
        assert_eq!(percent(None), MISSING);
        assert_eq!(bytes(Some(f64::NAN)), MISSING);
        assert_eq!(rate(Some(-1.0)), MISSING);
    }

    #[test]
    fn keeps_three_significant_figures_in_1024_steps() {
        assert_eq!(bytes(Some(0.0)), "0 B");
        assert_eq!(bytes(Some(512.0)), "512 B");
        assert_eq!(bytes(Some(1536.0)), "1.50 KB");
        assert_eq!(bytes(Some(20.0 * 1024.0 * 1024.0)), "20.0 MB");
        assert_eq!(bytes(Some(190.0 * 1024.0 * 1024.0)), "190 MB");
        assert_eq!(rate(Some(1024.0)), "1.00 KB/s");
    }

    #[test]
    fn axis_tops_drop_trailing_zeros() {
        assert_eq!(axis_rate(5.0 * 1024.0 * 1024.0), "5 MB/s");
        assert_eq!(axis_rate(1.5 * 1024.0 * 1024.0), "1.5 MB/s");
        assert_eq!(axis_rate(500.0 * 1024.0), "500 KB/s");
        assert_eq!(axis_rate(512.0), "512 B/s");
    }

    #[test]
    fn percents_have_one_decimal_only_under_ten() {
        assert_eq!(percent(Some(0.04)), "0.0%");
        assert_eq!(percent(Some(9.94)), "9.9%");
        assert_eq!(percent(Some(12.6)), "13%");
        assert_eq!(percent(Some(-3.0)), "0.0%");
    }
}
