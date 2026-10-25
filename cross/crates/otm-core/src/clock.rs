//! Wall-clock times in words, in the user's own time zone: Rust's standard
//! library has no local time, so the offset comes from the system (the C
//! library on Linux, the time zone API on Windows) for each moment, which
//! keeps summer and winter time right.

/// A UTC calendar date from days since 1970 (Howard Hinnant's algorithm).
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_index + 2) / 5 + 1) as u32;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// The date `time_ms` falls on in UTC, as 2026-10-25: names history files.
pub fn utc_date(time_ms: u64) -> String {
    let (year, month, day) = civil_from_days((time_ms / 86_400_000) as i64);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Seconds the user's time zone is ahead of UTC at `time_ms`, or None where the system won't say.
pub fn local_offset_seconds(time_ms: u64) -> Option<i64> {
    platform::offset(time_ms)
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];

/// `time_ms` as the user would say it, against `now_ms`: "14:05" today,
/// "Yesterday 14:05", "Tue 14:05" within the week, else "Oct 18 14:05".
/// Without the system's offset it's UTC, and says so.
pub fn moment(time_ms: u64, now_ms: u64) -> String {
    let (offset, zone) = match local_offset_seconds(time_ms) {
        Some(offset) => (offset, ""),
        None => (0, " UTC"),
    };
    let local = |ms: u64| ms as i64 / 1000 + offset;
    let (seconds, now) = (local(time_ms), local(now_ms));
    let (day, today) = (seconds.div_euclid(86_400), now.div_euclid(86_400));
    let clock = format!("{:02}:{:02}{zone}", seconds.rem_euclid(86_400) / 3600, seconds.rem_euclid(3600) / 60);
    match today - day {
        0 => clock,
        1 => format!("Yesterday {clock}"),
        2..=6 => format!("{} {clock}", WEEKDAYS[day.rem_euclid(7) as usize]),
        _ => {
            let (_, month, date) = civil_from_days(day);
            format!("{} {date} {clock}", MONTHS[month as usize - 1])
        }
    }
}

#[cfg(windows)]
mod platform {
    use windows_sys::Win32::Foundation::{FILETIME, SYSTEMTIME};
    use windows_sys::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTime};

    const UNIX_TO_1601: u64 = 11_644_473_600;

    fn system_time(seconds_since_1601: u64) -> Option<SYSTEMTIME> {
        let hundreds = seconds_since_1601 * 10_000_000;
        let file = FILETIME { dwLowDateTime: hundreds as u32, dwHighDateTime: (hundreds >> 32) as u32 };
        // SAFETY: SYSTEMTIME is plain numbers; all zeros is a valid value.
        let mut time = unsafe { std::mem::zeroed::<SYSTEMTIME>() };
        // SAFETY: both structures live on this stack frame for the call.
        (unsafe { FileTimeToSystemTime(&file, &mut time) } != 0).then_some(time)
    }

    fn seconds(time: &SYSTEMTIME) -> i64 {
        let days = super::days_from_civil(i64::from(time.wYear), u32::from(time.wMonth), u32::from(time.wDay));
        days * 86_400 + i64::from(time.wHour) * 3600 + i64::from(time.wMinute) * 60 + i64::from(time.wSecond)
    }

    pub fn offset(time_ms: u64) -> Option<i64> {
        let utc = system_time(time_ms / 1000 + UNIX_TO_1601)?;
        // SAFETY: as above.
        let mut local = unsafe { std::mem::zeroed::<SYSTEMTIME>() };
        // SAFETY: a null zone means the user's current one; both structures outlive the call.
        if unsafe { SystemTimeToTzSpecificLocalTime(std::ptr::null(), &utc, &mut local) } == 0 {
            return None;
        }
        Some(seconds(&local) - seconds(&utc))
    }
}

#[cfg(unix)]
mod platform {
    pub fn offset(time_ms: u64) -> Option<i64> {
        let time = libc::time_t::try_from(time_ms / 1000).ok()?;
        // SAFETY: tm is plain numbers and a pointer the call sets; all zeros is valid to pass.
        let mut parts = unsafe { std::mem::zeroed::<libc::tm>() };
        // SAFETY: localtime_r is the thread-safe form; both values outlive the call.
        let filled = unsafe { libc::localtime_r(&time, &mut parts) };
        // c_long: the same type on 64-bit systems, narrower on 32-bit ones.
        #[allow(clippy::useless_conversion)]
        let offset = i64::from(parts.tm_gmtoff);
        (!filled.is_null()).then_some(offset)
    }
}

#[cfg(not(any(windows, unix)))]
mod platform {
    pub fn offset(_time_ms: u64) -> Option<i64> {
        None
    }
}

/// Days since 1970 from a UTC calendar date (the inverse of `civil_from_days`).
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let month = i64::from(month);
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::{civil_from_days, days_from_civil, local_offset_seconds, moment, utc_date};

    #[test]
    fn dates_round_trip_through_days() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_386), (2025, 10, 25));
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
        assert_eq!(civil_from_days(11_016), (2000, 2, 29), "a leap day");
        for days in [-800_000, -1, 0, 59, 60, 11_016, 20_385, 2_000_000] {
            let (year, month, day) = civil_from_days(days);
            assert_eq!(days_from_civil(year, month, day), days);
        }
        assert_eq!(utc_date(1_761_350_400_000), "2025-10-25");
    }

    #[test]
    fn moments_read_as_people_say_them() {
        let offset = local_offset_seconds(1_761_350_400_000).unwrap_or(0) * 1000;
        // Noon, local, on Saturday 25 October 2025.
        let noon = (1_761_350_400_000i64 + 12 * 3_600_000 - offset) as u64;
        let zone = if local_offset_seconds(noon).is_some() { "" } else { " UTC" };
        assert_eq!(moment(noon, noon + 60_000), format!("12:00{zone}"));
        assert_eq!(moment(noon - 86_400_000, noon), format!("Yesterday 12:00{zone}"));
        assert_eq!(moment(noon - 3 * 86_400_000, noon), format!("Wed 12:00{zone}"));
        assert_eq!(moment(noon - 10 * 86_400_000, noon), format!("Oct 15 12:00{zone}"));
    }

    #[test]
    fn the_system_gives_an_offset_within_a_day() {
        let offset = local_offset_seconds(1_761_350_400_000).expect("this system's time zone");
        assert!(offset.abs() <= 14 * 3600);
    }
}
