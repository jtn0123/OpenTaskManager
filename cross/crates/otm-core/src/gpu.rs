//! GPU load, which `sysinfo` doesn't read. A GPU is as busy as its busiest
//! engine (3D, copy, video), as Windows' Task Manager reports it, and so is
//! a process. Windows gives every process's engine time through its
//! performance counters; Linux through each DRM client's `fdinfo`, which
//! this account can read only for its own processes (all, as root).
//!
//! Like other rates, the first reading after a pause only primes.

use std::collections::HashMap;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct GpuReading {
    /// The busiest engine of the busiest GPU, 0–100.
    pub busy: f32,
    /// Each process's busiest engine, 0–100, for the processes that could
    /// be read; one using no GPU reads 0.
    pub processes: HashMap<u32, f32>,
    /// Whether a process missing from `processes` is idle (true) or simply
    /// couldn't be read (false: another account's, on Linux).
    pub complete: bool,
    /// Bytes of GPU memory in use, where the system says.
    pub memory_used: Option<u64>,
}

impl GpuReading {
    /// `pid`'s share, or None when it couldn't be read.
    pub fn process(&self, pid: u32) -> Option<f32> {
        self.processes.get(&pid).copied().or(self.complete.then_some(0.0))
    }
}

/// Reads GPU load; None from `new` where this system offers no reading.
pub struct GpuReader(platform::Reader);

impl GpuReader {
    pub fn new() -> Option<Self> {
        platform::Reader::new().map(Self)
    }

    /// The load since the previous call, or None on the first call (or a failed read).
    pub fn read(&mut self) -> Option<GpuReading> {
        self.0.read()
    }
}

/// Windows' "GPU Engine" instances, named like
/// `pid_1234_luid_0x0_0xD1B8_phys_0_eng_3_engtype_VideoDecode`, as (busy
/// share, per process): each engine's load sums its processes', and a GPU's
/// and a process's load is its busiest engine.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn engine_loads(instances: &[(String, f64)]) -> (f32, HashMap<u32, f32>) {
    let mut engines: HashMap<&str, f64> = HashMap::new();
    let mut by_process: HashMap<(u32, &str), f64> = HashMap::new();
    for (name, value) in instances {
        let Some(pid) = name.strip_prefix("pid_").and_then(|rest| rest.split('_').next()?.parse::<u32>().ok()) else {
            continue;
        };
        let Some(start) = name.find("luid_") else { continue };
        let engine = &name[start..name.find("_engtype").unwrap_or(name.len())];
        if !value.is_finite() || *value < 0.0 {
            continue;
        }
        *engines.entry(engine).or_default() += value;
        *by_process.entry((pid, engine)).or_default() += value;
    }
    let busy = engines.values().fold(0.0f64, |most, value| most.max(*value)).min(100.0) as f32;
    let mut processes: HashMap<u32, f32> = HashMap::new();
    for ((pid, _), value) in by_process {
        let share = value.min(100.0) as f32;
        let entry = processes.entry(pid).or_default();
        *entry = entry.max(share);
    }
    (busy, processes)
}

/// One DRM client as a process's `fdinfo` describes it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct DrmClient {
    /// The device: its PCI address, or the driver where none is given.
    pub device: String,
    pub id: Option<u64>,
    /// Engine, and its counter: busy nanoseconds over this many units, or
    /// busy cycles out of total cycles.
    pub engines: Vec<(String, EngineTime)>,
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum EngineTime {
    Nanoseconds { busy: u64, units: u64 },
    Cycles { busy: u64, total: u64 },
}

/// Parses a `/proc/PID/fdinfo/FD` file; None unless it's a DRM client.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn parse_fdinfo(text: &str) -> Option<DrmClient> {
    let mut driver = None;
    let mut device = None;
    let mut id = None;
    let mut nanoseconds: HashMap<String, u64> = HashMap::new();
    let mut units: HashMap<String, u64> = HashMap::new();
    let mut cycles: HashMap<String, u64> = HashMap::new();
    let mut totals: HashMap<String, u64> = HashMap::new();
    let number = |value: &str| value.split_whitespace().next()?.parse::<u64>().ok();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else { continue };
        let value = value.trim();
        if key == "drm-driver" {
            driver = Some(value.to_owned());
        } else if key == "drm-pdev" {
            device = Some(value.to_owned());
        } else if key == "drm-client-id" {
            id = number(value);
        } else {
            // Engine counters; a line whose figure doesn't read is left out.
            let (counters, engine) = if let Some(engine) = key.strip_prefix("drm-engine-capacity-") {
                (&mut units, engine)
            } else if let Some(engine) = key.strip_prefix("drm-engine-") {
                (&mut nanoseconds, engine)
            } else if let Some(engine) = key.strip_prefix("drm-total-cycles-") {
                (&mut totals, engine)
            } else if let Some(engine) = key.strip_prefix("drm-cycles-") {
                (&mut cycles, engine)
            } else {
                continue;
            };
            if let Some(figure) = number(value) {
                counters.insert(engine.to_owned(), figure);
            }
        }
    }
    let driver = driver?;
    let mut engines: Vec<(String, EngineTime)> = nanoseconds
        .into_iter()
        .map(|(engine, busy)| {
            let units = units.get(&engine).copied().unwrap_or(1).max(1);
            (engine, EngineTime::Nanoseconds { busy, units })
        })
        .collect();
    engines.extend(cycles.into_iter().filter_map(|(engine, busy)| {
        let total = *totals.get(&engine)?;
        Some((engine, EngineTime::Cycles { busy, total }))
    }));
    engines.sort_by(|a, b| a.0.cmp(&b.0));
    Some(DrmClient { device: device.unwrap_or(driver), id, engines })
}

/// An engine's share busy, 0–100, between two readings `seconds` apart.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn engine_share(before: EngineTime, now: EngineTime, seconds: f64) -> Option<f64> {
    match (before, now) {
        (EngineTime::Nanoseconds { busy: was, .. }, EngineTime::Nanoseconds { busy, units }) if seconds > 0.0 => {
            let spent = busy.checked_sub(was)? as f64;
            Some((spent / (seconds * 1e9 * units as f64) * 100.0).min(100.0))
        }
        (EngineTime::Cycles { busy: was, total: before }, EngineTime::Cycles { busy, total }) => {
            let span = total.checked_sub(before)?;
            (span > 0).then(|| (busy.saturating_sub(was) as f64 / span as f64 * 100.0).min(100.0))
        }
        _ => None,
    }
}

#[cfg(windows)]
mod platform {
    use std::ptr;

    use windows_sys::Win32::System::Performance::{
        PDH_CSTATUS_NEW_DATA, PDH_CSTATUS_VALID_DATA, PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE, PDH_HCOUNTER,
        PDH_HQUERY, PDH_MORE_DATA, PdhAddEnglishCounterW, PdhCloseQuery, PdhCollectQueryData,
        PdhGetFormattedCounterArrayW, PdhOpenQueryW,
    };

    use super::{GpuReading, engine_loads};

    pub struct Reader {
        query: PDH_HQUERY,
        engines: PDH_HCOUNTER,
        memory: Option<PDH_HCOUNTER>,
        primed: bool,
    }

    // SAFETY: PDH handles may be used from any thread, one at a time, which `&mut self` ensures.
    unsafe impl Send for Reader {}

    impl Drop for Reader {
        fn drop(&mut self) {
            // SAFETY: the query was opened in `new` and is closed only here, with its counters.
            unsafe { PdhCloseQuery(self.query) };
        }
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain([0]).collect()
    }

    fn add(query: PDH_HQUERY, path: &str) -> Option<PDH_HCOUNTER> {
        let path = wide(path);
        let mut counter: PDH_HCOUNTER = ptr::null_mut();
        // SAFETY: the query is open; `path` is NUL-terminated and outlives the call.
        (unsafe { PdhAddEnglishCounterW(query, path.as_ptr(), 0, &mut counter) } == 0).then_some(counter)
    }

    /// Every instance's value, by name; None if the counter can't be read.
    fn values(counter: PDH_HCOUNTER) -> Option<Vec<(String, f64)>> {
        let (mut size, mut count) = (0u32, 0u32);
        // SAFETY: a null buffer asks for the size the items need.
        let status =
            unsafe { PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &mut size, &mut count, ptr::null_mut()) };
        if status == 0 {
            return Some(Vec::new());
        }
        if status != PDH_MORE_DATA {
            return None;
        }
        // u64s keep the items' doubles aligned; the names live in the same buffer.
        let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
        let items = buffer.as_mut_ptr().cast::<PDH_FMT_COUNTERVALUE_ITEM_W>();
        // SAFETY: `buffer` holds `size` bytes, aligned for the items, as the first call asked.
        if unsafe { PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &mut size, &mut count, items) } != 0 {
            return None;
        }
        let mut found = Vec::with_capacity(count as usize);
        for index in 0..count as usize {
            // SAFETY: PDH wrote `count` items at the start of `buffer`.
            let item = unsafe { &*items.add(index) };
            let status = item.FmtValue.CStatus;
            if status != PDH_CSTATUS_VALID_DATA && status != PDH_CSTATUS_NEW_DATA {
                continue;
            }
            // SAFETY: the name is a NUL-terminated string inside `buffer`, alive until it's dropped.
            let name = unsafe {
                let mut length = 0;
                while *item.szName.add(length) != 0 {
                    length += 1;
                }
                String::from_utf16_lossy(std::slice::from_raw_parts(item.szName, length))
            };
            // SAFETY: PDH_FMT_DOUBLE fills the union's double.
            found.push((name, unsafe { item.FmtValue.Anonymous.doubleValue }));
        }
        Some(found)
    }

    impl Reader {
        pub fn new() -> Option<Self> {
            let mut query: PDH_HQUERY = ptr::null_mut();
            // SAFETY: opens a query on this machine's live data; `query` receives it.
            if unsafe { PdhOpenQueryW(ptr::null(), 0, &mut query) } != 0 {
                return None;
            }
            let Some(engines) = add(query, r"\GPU Engine(*)\Utilization Percentage") else {
                // SAFETY: the query was just opened and is closed once.
                unsafe { PdhCloseQuery(query) };
                return None;
            };
            let memory = add(query, r"\GPU Adapter Memory(*)\Dedicated Usage");
            Some(Self { query, engines, memory, primed: false })
        }

        pub fn read(&mut self) -> Option<GpuReading> {
            // SAFETY: the query is open.
            if unsafe { PdhCollectQueryData(self.query) } != 0 {
                self.primed = false;
                return None;
            }
            if !std::mem::replace(&mut self.primed, true) {
                return None;
            }
            let (busy, processes) = engine_loads(&values(self.engines)?);
            let memory_used = self
                .memory
                .and_then(values)
                .filter(|adapters| !adapters.is_empty())
                .map(|adapters| adapters.iter().map(|(_, bytes)| bytes.max(0.0) as u64).sum());
            Some(GpuReading { busy, processes, complete: true, memory_used })
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::collections::HashMap;
    use std::fs;
    use std::time::{Duration, Instant};

    use super::{EngineTime, GpuReading, engine_share, parse_fdinfo};

    /// How long a process's list of open GPU files is trusted before it's read again.
    const RESCAN: Duration = Duration::from_secs(10);

    type Counter = (String, u64, String);

    pub struct Reader {
        last: Option<(Instant, HashMap<Counter, EngineTime>)>,
        /// Each process's open DRM files, and when they were listed.
        files: HashMap<u32, (Instant, Vec<String>)>,
        complete: bool,
    }

    impl Reader {
        pub fn new() -> Option<Self> {
            let devices = fs::read_dir("/dev/dri").ok()?;
            let any = devices.flatten().any(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                name.starts_with("renderD") || name.starts_with("card")
            });
            any.then(|| Self { last: None, files: HashMap::new(), complete: rustix::process::geteuid().is_root() })
        }

        /// The fd numbers of `pid`'s open DRM device files; None if they can't be listed.
        fn drm_files(&mut self, pid: u32, now: Instant) -> Option<Vec<String>> {
            if let Some((listed, files)) = self.files.get(&pid)
                && now.duration_since(*listed) < RESCAN
            {
                return Some(files.clone());
            }
            let mut found = Vec::new();
            for entry in fs::read_dir(format!("/proc/{pid}/fd")).ok()?.flatten() {
                if fs::read_link(entry.path()).is_ok_and(|target| target.starts_with("/dev/dri/")) {
                    found.push(entry.file_name().to_string_lossy().into_owned());
                }
            }
            self.files.insert(pid, (now, found.clone()));
            Some(found)
        }

        pub fn read(&mut self) -> Option<GpuReading> {
            let now = Instant::now();
            let mut counters: HashMap<Counter, EngineTime> = HashMap::new();
            let mut owners: HashMap<u32, Vec<(String, u64)>> = HashMap::new();
            let mut readable = Vec::new();
            let pids: Vec<u32> = fs::read_dir("/proc")
                .ok()?
                .flatten()
                .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
                .collect();
            self.files.retain(|pid, _| pids.contains(pid));
            for pid in pids {
                let Some(files) = self.drm_files(pid, now) else { continue };
                readable.push(pid);
                for fd in files {
                    let Ok(text) = fs::read_to_string(format!("/proc/{pid}/fdinfo/{fd}")) else { continue };
                    let Some(client) = parse_fdinfo(&text) else { continue };
                    // A client without an id can't be told from another; count it under its file.
                    let id = client.id.unwrap_or_else(|| u64::from(pid) << 32 | fd.parse::<u64>().unwrap_or(0));
                    for (engine, time) in client.engines {
                        counters.insert((client.device.clone(), id, engine), time);
                    }
                    owners.entry(pid).or_default().push((client.device, id));
                }
            }
            let previous = self.last.replace((now, counters));
            let (then, before) = previous?;
            let (_, counters) = self.last.as_ref()?;
            let seconds = now.duration_since(then).as_secs_f64();
            let shares: HashMap<&Counter, f64> = counters
                .iter()
                .filter_map(|(counter, time)| Some((counter, engine_share(*before.get(counter)?, *time, seconds)?)))
                .collect();
            // Each device's engines sum their clients'; a GPU is its busiest engine.
            let mut engines: HashMap<(&str, &str), f64> = HashMap::new();
            for ((device, _, engine), share) in &shares {
                *engines.entry((device.as_str(), engine.as_str())).or_default() += share;
            }
            let busy = engines.values().fold(0.0f64, |most, share| most.max(*share)).min(100.0) as f32;
            let mut processes: HashMap<u32, f32> = readable.into_iter().map(|pid| (pid, 0.0)).collect();
            for (pid, clients) in owners {
                let mut mine: HashMap<&str, f64> = HashMap::new();
                let mut seen = Vec::new();
                for client in &clients {
                    if seen.contains(&client) {
                        continue;
                    }
                    seen.push(client);
                    for ((device, id, engine), share) in &shares {
                        if *device == client.0 && *id == client.1 {
                            *mine.entry(engine.as_str()).or_default() += share;
                        }
                    }
                }
                let most = mine.values().fold(0.0f64, |most, share| most.max(*share)).min(100.0) as f32;
                processes.insert(pid, most);
            }
            Some(GpuReading { busy, processes, complete: self.complete, memory_used: None })
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod platform {
    use super::GpuReading;

    pub struct Reader;

    impl Reader {
        pub fn new() -> Option<Self> {
            None
        }

        pub fn read(&mut self) -> Option<GpuReading> {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{EngineTime, GpuReading, engine_loads, engine_share, parse_fdinfo};

    /// Live, on Windows: this machine's counters, so it checks shapes, not values.
    #[cfg(windows)]
    #[test]
    fn reads_this_machines_gpu_after_priming() {
        use std::time::{Duration, Instant};
        let Some(mut reader) = super::GpuReader::new() else { return };
        assert!(reader.read().is_none(), "the first reading primes");
        std::thread::sleep(Duration::from_millis(400));
        let started = Instant::now();
        let reading = reader.read().expect("a reading once primed");
        let took = started.elapsed();
        eprintln!(
            "GPU read: {took:?}, busy {}%, {} processes, memory {:?}",
            reading.busy,
            reading.processes.len(),
            reading.memory_used
        );
        assert!((0.0..=100.0).contains(&reading.busy));
        assert!(reading.complete, "Windows counts every process");
        assert!(reading.processes.values().all(|share| (0.0..=100.0).contains(share)));
    }

    #[test]
    fn a_gpu_and_a_process_are_as_busy_as_their_busiest_engine() {
        let instance = |pid: u32, engine: u32, kind: &str, value: f64| {
            (format!("pid_{pid}_luid_0x00000000_0x0000D1B8_phys_0_eng_{engine}_engtype_{kind}"), value)
        };
        let samples = [
            instance(100, 0, "3D", 30.0),
            instance(100, 0, "3D", 5.0),
            instance(100, 3, "VideoDecode", 20.0),
            instance(200, 0, "3D", 40.0),
            instance(300, 1, "Copy", 0.0),
            ("not an engine".to_owned(), 99.0),
        ];
        let (busy, processes) = engine_loads(&samples);
        assert_eq!(busy, 75.0, "the 3D engine: 35 + 40");
        assert_eq!(processes[&100], 35.0, "its two 3D contexts, over its video decoding");
        assert_eq!(processes[&200], 40.0);
        assert_eq!(processes[&300], 0.0);
        assert!(!processes.contains_key(&0));
    }

    #[test]
    fn a_process_the_counters_dont_list_is_idle_only_where_every_process_was_read() {
        let reading = GpuReading { complete: true, ..GpuReading::default() };
        assert_eq!(reading.process(7), Some(0.0));
        let partial = GpuReading { complete: false, ..GpuReading::default() };
        assert_eq!(partial.process(7), None);
    }

    #[test]
    fn parses_amd_and_intel_fdinfo() {
        let amd = "pos:\t0\nflags:\t02100002\ndrm-driver:\tamdgpu\ndrm-pdev:\t0000:03:00.0\ndrm-client-id:\t42\n\
                   drm-engine-gfx:\t1500000000 ns\ndrm-engine-compute:\t0 ns\ndrm-memory-vram:\t1024 KiB\n";
        let client = parse_fdinfo(amd).expect("a DRM client");
        assert_eq!(client.device, "0000:03:00.0");
        assert_eq!(client.id, Some(42));
        assert_eq!(
            client.engines,
            [
                ("compute".to_owned(), EngineTime::Nanoseconds { busy: 0, units: 1 }),
                ("gfx".to_owned(), EngineTime::Nanoseconds { busy: 1_500_000_000, units: 1 }),
            ]
        );
        let xe = "drm-driver:\txe\ndrm-client-id:\t7\ndrm-cycles-rcs:\t500\ndrm-total-cycles-rcs:\t2000\n";
        let client = parse_fdinfo(xe).expect("a DRM client");
        assert_eq!(client.device, "xe", "no PCI address: the driver names it");
        assert_eq!(client.engines, [("rcs".to_owned(), EngineTime::Cycles { busy: 500, total: 2000 })]);
        assert_eq!(parse_fdinfo("pos:\t0\nflags:\t0100002\n"), None, "an ordinary file");
    }

    #[test]
    fn engine_shares_come_from_two_readings() {
        let at = |busy| EngineTime::Nanoseconds { busy, units: 2 };
        assert_eq!(engine_share(at(0), at(1_000_000_000), 1.0), Some(50.0), "one of two units for the second");
        let cycles = |busy, total| EngineTime::Cycles { busy, total };
        assert_eq!(engine_share(cycles(100, 1000), cycles(400, 2000), 1.0), Some(30.0));
        assert_eq!(engine_share(at(5), at(1), 1.0), None, "a counter that went back");
    }
}
