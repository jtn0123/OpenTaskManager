//! The history recorder: one record every 10 s of what the machine did
//! (averages over the span, CPU's peak, the busiest processes), appended
//! to a text file per UTC day and kept for 7 days. Time the app wasn't
//! running, or the machine slept, has no record: History shows a gap
//! there, never a zero.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::clock::{civil_from_days, utc_date};
use crate::model::{ProcessKey, ProcessRow, Snapshot};
use crate::rows::machine_share;

/// Each record's span.
pub const SPAN_MS: u64 = 10_000;
/// Days of records kept.
pub const KEEP_DAYS: u64 = 7;
/// Processes kept per record: the busiest by CPU, and by memory.
const TOP: usize = 5;

/// One of the busiest processes in a span, as the table showed it.
#[derive(Clone, Debug, PartialEq)]
pub struct TopProcess {
    pub key: ProcessKey,
    pub name: String,
    /// Share of the whole machine's CPU, 0–100.
    pub cpu: Option<f32>,
    pub memory: Option<u64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    /// Milliseconds since 1970 when the span's last sample ended.
    pub time_ms: u64,
    /// How much time the record covers, at most `SPAN_MS`.
    pub span_ms: u64,
    /// Busy share of the whole CPU, averaged, and its highest sample.
    pub cpu: f32,
    pub cpu_peak: f32,
    pub memory_used: u64,
    pub memory_total: u64,
    /// Bytes per second, averaged; None where nothing reported it.
    pub disk_read: Option<f64>,
    pub disk_write: Option<f64>,
    pub net_in: Option<f64>,
    pub net_out: Option<f64>,
    /// The busiest GPU engine, averaged over the samples that read it.
    pub gpu: Option<f32>,
    /// The busiest processes at the span's last process reading; empty
    /// when processes weren't read in it.
    pub top: Vec<TopProcess>,
}

/// A time-weighted mean.
#[derive(Clone, Copy, Default)]
struct Mean {
    sum: f64,
    weight: f64,
}

impl Mean {
    fn add(&mut self, value: Option<f64>, weight: f64) {
        if let Some(value) = value.filter(|value| value.is_finite()) {
            self.sum += value * weight;
            self.weight += weight;
        }
    }

    fn get(self) -> Option<f64> {
        (self.weight > 0.0).then(|| self.sum / self.weight)
    }
}

struct Open {
    span: u64,
    first_ms: u64,
    last_ms: u64,
    cpu: Mean,
    cpu_peak: f32,
    memory: Mean,
    memory_total: u64,
    disk: (Mean, Mean),
    net: (Mean, Mean),
    gpu: Mean,
    top: Vec<TopProcess>,
}

impl Open {
    fn finish(self) -> Record {
        Record {
            time_ms: self.last_ms,
            span_ms: (self.last_ms - self.first_ms).min(SPAN_MS),
            cpu: self.cpu.get().unwrap_or(0.0) as f32,
            cpu_peak: self.cpu_peak,
            memory_used: self.memory.get().unwrap_or(0.0) as u64,
            memory_total: self.memory_total,
            disk_read: self.disk.0.get(),
            disk_write: self.disk.1.get(),
            net_in: self.net.0.get(),
            net_out: self.net.1.get(),
            gpu: self.gpu.get().map(|share| share as f32),
            top: self.top,
        }
    }
}

/// Gathers samples into records, one per 10 s of wall-clock time.
#[derive(Default)]
pub struct Accumulator {
    open: Option<Open>,
}

impl Accumulator {
    /// Adds one sample, and the processes read with it if any. Returns the
    /// previous span's record once a sample falls in a new span.
    pub fn add(
        &mut self,
        snapshot: &Snapshot,
        processes: Option<&[ProcessRow]>,
        logical_cpus: usize,
    ) -> Option<Record> {
        let span = snapshot.time_ms / SPAN_MS;
        let finished = match &self.open {
            Some(open) if open.span != span => self.open.take().map(Open::finish),
            _ => None,
        };
        let covered_ms = (snapshot.interval * 1000.0) as u64;
        let open = self.open.get_or_insert_with(|| Open {
            span,
            first_ms: snapshot.time_ms.saturating_sub(covered_ms).max(span * SPAN_MS),
            last_ms: snapshot.time_ms,
            cpu: Mean::default(),
            cpu_peak: 0.0,
            memory: Mean::default(),
            memory_total: snapshot.memory_total,
            disk: (Mean::default(), Mean::default()),
            net: (Mean::default(), Mean::default()),
            gpu: Mean::default(),
            top: Vec::new(),
        });
        let weight = snapshot.interval.max(0.001);
        open.last_ms = snapshot.time_ms;
        open.cpu.add(Some(f64::from(snapshot.cpu)), weight);
        open.cpu_peak = open.cpu_peak.max(snapshot.cpu);
        open.memory.add(Some(snapshot.memory_used as f64), weight);
        open.memory_total = snapshot.memory_total;
        open.disk.0.add(snapshot.disk.map(|disk| disk.read), weight);
        open.disk.1.add(snapshot.disk.map(|disk| disk.write), weight);
        open.net.0.add(snapshot.network.map(|network| network.received), weight);
        open.net.1.add(snapshot.network.map(|network| network.sent), weight);
        open.gpu.add(snapshot.gpu.map(f64::from), weight);
        if let Some(processes) = processes {
            open.top = top(processes, logical_cpus);
        }
        finished
    }
}

/// The busiest processes: the top by CPU and the top by memory, together.
pub fn top(processes: &[ProcessRow], logical_cpus: usize) -> Vec<TopProcess> {
    let entry = |row: &ProcessRow| TopProcess {
        key: row.key,
        name: row.name.clone(),
        cpu: machine_share(row, logical_cpus).map(|share| share as f32),
        memory: row.memory,
    };
    let mut by_cpu: Vec<&ProcessRow> = processes.iter().filter(|row| row.cpu.is_some()).collect();
    by_cpu.sort_by(|a, b| b.cpu.unwrap_or(0.0).total_cmp(&a.cpu.unwrap_or(0.0)).then(a.key.pid.cmp(&b.key.pid)));
    let mut by_memory: Vec<&ProcessRow> = processes.iter().filter(|row| row.memory.is_some()).collect();
    by_memory.sort_by(|a, b| b.memory.cmp(&a.memory).then(a.key.pid.cmp(&b.key.pid)));
    let mut kept: Vec<TopProcess> = Vec::with_capacity(TOP * 2);
    for row in by_cpu.into_iter().take(TOP).chain(by_memory.into_iter().take(TOP)) {
        if !kept.iter().any(|kept| kept.key == row.key) {
            kept.push(entry(row));
        }
    }
    kept
}

fn optional<T: std::fmt::Display>(value: Option<T>) -> String {
    value.map_or_else(|| "-".to_owned(), |value| value.to_string())
}

/// One line of a history file: the figures, space-separated, "-" where
/// unknown; then each process, tab-separated, its name last.
pub fn encode(record: &Record) -> String {
    let rate = |value: Option<f64>| optional(value.map(|value| value.round() as u64));
    let mut line = format!(
        "v1 {} {} {:.1} {:.1} {} {} {} {} {} {} {}",
        record.time_ms,
        record.span_ms,
        record.cpu,
        record.cpu_peak,
        record.memory_used,
        record.memory_total,
        rate(record.disk_read),
        rate(record.disk_write),
        rate(record.net_in),
        rate(record.net_out),
        optional(record.gpu.map(|share| format!("{share:.1}"))),
    );
    for process in &record.top {
        let name: String = process.name.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        line += &format!(
            "\t{} {} {} {} {}",
            process.key.pid,
            process.key.start_time,
            optional(process.cpu.map(|share| format!("{share:.1}"))),
            optional(process.memory),
            name
        );
    }
    line
}

/// Reads a line `encode` wrote; None for anything else.
pub fn decode(line: &str) -> Option<Record> {
    let mut fields = line.split('\t');
    let figures: Vec<&str> = fields.next()?.split(' ').collect();
    if figures.len() != 12 || figures[0] != "v1" {
        return None;
    }
    let number = |at: usize| figures[at].parse::<f64>().ok();
    let maybe = |at: usize| if figures[at] == "-" { Some(None) } else { number(at).map(Some) };
    let mut top = Vec::new();
    for field in fields {
        let parts: Vec<&str> = field.splitn(5, ' ').collect();
        let [pid, start, cpu, memory, name] = parts[..] else { return None };
        top.push(TopProcess {
            key: ProcessKey { pid: pid.parse().ok()?, start_time: start.parse().ok()? },
            name: name.to_owned(),
            cpu: if cpu == "-" { None } else { Some(cpu.parse().ok()?) },
            memory: if memory == "-" { None } else { Some(memory.parse().ok()?) },
        });
    }
    Some(Record {
        time_ms: figures[1].parse().ok()?,
        span_ms: figures[2].parse().ok()?,
        cpu: number(3)? as f32,
        cpu_peak: number(4)? as f32,
        memory_used: figures[5].parse().ok()?,
        memory_total: figures[6].parse().ok()?,
        disk_read: maybe(7)?,
        disk_write: maybe(8)?,
        net_in: maybe(9)?,
        net_out: maybe(10)?,
        gpu: maybe(11)?.map(|share| share as f32),
        top,
    })
}

/// The history files for one instance of the app.
pub struct Store {
    folder: PathBuf,
}

impl Store {
    pub fn at(folder: impl Into<PathBuf>) -> Self {
        Self { folder: folder.into() }
    }

    /// The user's own history ("default"), or a test instance's beside it.
    pub fn for_instance(instance: &str) -> Option<Self> {
        let name =
            if instance == crate::instance::DEFAULT { "history".to_owned() } else { format!("history-{instance}") };
        data_folder().map(|folder| Self::at(folder.join(name)))
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    fn file(&self, day: u64) -> PathBuf {
        self.folder.join(format!("{}.history", utc_date(day * 86_400_000)))
    }

    pub fn append(&self, record: &Record) -> io::Result<()> {
        fs::create_dir_all(&self.folder)?;
        let mut file = OpenOptions::new().create(true).append(true).open(self.file(record.time_ms / 86_400_000))?;
        writeln!(file, "{}", encode(record))
    }

    /// Records that ended from `from_ms` up to `to_ms`, oldest first.
    pub fn read(&self, from_ms: u64, to_ms: u64) -> Vec<Record> {
        let mut records = Vec::new();
        for day in from_ms / 86_400_000..=to_ms / 86_400_000 {
            let Ok(text) = fs::read_to_string(self.file(day)) else { continue };
            records
                .extend(text.lines().filter_map(decode).filter(|record| (from_ms..=to_ms).contains(&record.time_ms)));
        }
        records.sort_by_key(|record| record.time_ms);
        records
    }

    /// Deletes days older than `KEEP_DAYS` before `now_ms`; returns how many files went.
    pub fn prune(&self, now_ms: u64) -> io::Result<usize> {
        let oldest_kept = (now_ms / 86_400_000).saturating_sub(KEEP_DAYS - 1);
        let mut removed = 0;
        let Ok(entries) = fs::read_dir(&self.folder) else { return Ok(0) };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(day) = name.strip_suffix(".history").and_then(day_of) else { continue };
            if day < oldest_kept {
                fs::remove_file(entry.path())?;
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Bytes the history takes on disk.
    pub fn size(&self) -> u64 {
        fs::read_dir(&self.folder)
            .map(|entries| entries.flatten().filter_map(|entry| entry.metadata().ok()).map(|meta| meta.len()).sum())
            .unwrap_or(0)
    }
}

/// Days since 1970 from a file's "2026-10-25".
fn day_of(date: &str) -> Option<u64> {
    let mut parts = date.split('-').map(|part| part.parse::<i64>().ok());
    let (year, month, day) = (parts.next()??, parts.next()??, parts.next()??);
    let days = crate::clock::days_from_civil(year, u32::try_from(month).ok()?, u32::try_from(day).ok()?);
    // Only a real date round-trips.
    (civil_from_days(days) == (year, month as u32, day as u32)).then_some(days as u64)
}

#[cfg(windows)]
fn data_folder() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|folder| PathBuf::from(folder).join("OpenTaskManager"))
}

#[cfg(target_os = "macos")]
fn data_folder() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Library/Application Support/OpenTaskManager"))
}

#[cfg(not(any(windows, target_os = "macos")))]
fn data_folder() -> Option<PathBuf> {
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))?;
    Some(data.join("opentaskmanager"))
}

/// Values for `buckets` equal slices of `from_ms..to_ms`: each slice takes
/// the mean of the records covering it; a slice no record covers is None,
/// drawn as a gap.
pub fn series(
    records: &[Record],
    from_ms: u64,
    to_ms: u64,
    buckets: usize,
    pick: impl Fn(&Record) -> Option<f64>,
) -> Vec<Option<f64>> {
    let mut sums = vec![Mean::default(); buckets];
    let width = (to_ms.saturating_sub(from_ms)) as f64 / buckets.max(1) as f64;
    for record in records {
        let Some(value) = pick(record) else { continue };
        let start = record.time_ms.saturating_sub(record.span_ms.max(1000));
        let first = ((start.saturating_sub(from_ms)) as f64 / width).floor() as usize;
        let last = ((record.time_ms.saturating_sub(from_ms)) as f64 / width).ceil() as usize;
        if record.time_ms < from_ms || start > to_ms {
            continue;
        }
        for bucket in sums.iter_mut().take(last.min(buckets)).skip(first) {
            bucket.add(Some(value), 1.0);
        }
    }
    sums.into_iter().map(Mean::get).collect()
}

/// The record covering `time_ms`, or one within half a span of it; None in a gap.
pub fn at(records: &[Record], time_ms: u64) -> Option<&Record> {
    let distance = |record: &Record| {
        let start = record.time_ms.saturating_sub(record.span_ms);
        if time_ms < start { start - time_ms } else { time_ms.saturating_sub(record.time_ms) }
    };
    records.iter().min_by_key(|record| distance(record)).filter(|record| distance(record) <= SPAN_MS / 2)
}

#[cfg(test)]
mod tests {
    use super::{Accumulator, Record, SPAN_MS, Store, TopProcess, at, decode, encode, series, top};
    use crate::model::{DiskRates, ProcessKey, ProcessRow, Snapshot};

    fn snapshot(time_ms: u64, cpu: f32) -> Snapshot {
        Snapshot {
            time_ms,
            interval: 1.0,
            cpu,
            cores: vec![cpu; 2],
            memory_used: 1000,
            memory_total: 4000,
            swap_used: 0,
            swap_total: 0,
            disk: Some(DiskRates { read: 100.0, write: 0.0 }),
            network: None,
            gpu: None,
            gpu_memory: None,
        }
    }

    fn process(pid: u32, cpu: Option<f32>, memory: Option<u64>) -> ProcessRow {
        ProcessRow {
            key: ProcessKey { pid, start_time: 7 },
            parent: None,
            name: format!("p{pid}"),
            user: None,
            cpu,
            gpu: None,
            memory,
            disk_read: None,
            disk_write: None,
        }
    }

    fn record(time_ms: u64, cpu: f32) -> Record {
        Record {
            time_ms,
            span_ms: SPAN_MS,
            cpu,
            cpu_peak: cpu,
            memory_used: 1,
            memory_total: 2,
            disk_read: None,
            disk_write: None,
            net_in: None,
            net_out: None,
            gpu: None,
            top: Vec::new(),
        }
    }

    #[test]
    fn records_each_ten_seconds_of_wall_clock_time() {
        let mut accumulator = Accumulator::default();
        let base = 1_000_000_000;
        let mut records = Vec::new();
        for second in 0..25 {
            let processes = (second == 5).then(|| vec![process(1, Some(200.0), Some(10)), process(2, None, Some(99))]);
            if let Some(record) =
                accumulator.add(&snapshot(base + second * 1000, second as f32), processes.as_deref(), 4)
            {
                records.push(record);
            }
        }
        assert_eq!(records.len(), 2, "two spans closed, the third still open");
        assert_eq!(records[0].time_ms, base + 9000);
        assert_eq!(records[0].cpu, 4.5, "the mean of 0 to 9");
        assert_eq!(records[0].cpu_peak, 9.0);
        assert_eq!(records[0].disk_read, Some(100.0));
        assert_eq!(records[0].net_in, None, "nothing reported is unknown, not zero");
        assert_eq!(records[0].top.len(), 2);
        assert_eq!(records[0].top[0].cpu, Some(50.0), "as a share of four CPUs");
        assert!(records[1].top.is_empty(), "no process reading in that span");
    }

    #[test]
    fn keeps_the_busiest_by_cpu_and_by_memory() {
        let processes: Vec<ProcessRow> =
            (1..=12).map(|pid| process(pid, Some(pid as f32), Some(1000 - u64::from(pid)))).collect();
        let kept: Vec<u32> = top(&processes, 1).iter().map(|process| process.key.pid).collect();
        assert_eq!(kept, [12, 11, 10, 9, 8, 1, 2, 3, 4, 5]);
    }

    #[test]
    fn lines_round_trip_and_bad_ones_are_skipped() {
        let mut original = record(1_761_350_400_000, 12.5);
        original.disk_read = Some(1234.0);
        original.gpu = Some(3.5);
        original.top = vec![
            TopProcess {
                key: ProcessKey { pid: 42, start_time: 9 },
                name: "My App.exe".to_owned(),
                cpu: Some(1.5),
                memory: None,
            },
            TopProcess {
                key: ProcessKey { pid: 7, start_time: 1 },
                name: "tab\there".to_owned(),
                cpu: None,
                memory: Some(5),
            },
        ];
        let line = encode(&original);
        let mut expected = original.clone();
        expected.top[1].name = "tab here".to_owned();
        assert_eq!(decode(&line), Some(expected));
        assert_eq!(decode("v2 1 2 3"), None);
        assert_eq!(decode(""), None);
        assert_eq!(decode(&line.replace(" 12.5 ", " x ")), None);
    }

    #[test]
    fn stores_days_and_prunes_the_old_ones() {
        let folder = std::env::temp_dir().join(format!("otm-history-test-{}", std::process::id()));
        let store = Store::at(&folder);
        let day = 86_400_000;
        let now = 20_000 * day + 5000;
        for days_ago in [0, 1, 7, 8] {
            store.append(&record(now - days_ago * day, days_ago as f32)).expect("written");
        }
        store.append(&record(now - 10_000, 1.0)).expect("written");
        assert_eq!(store.read(now - day - 1, now).len(), 3);
        assert_eq!(store.prune(now).expect("pruned"), 2, "days 7 and 8 back are past the week");
        assert_eq!(store.read(0, now).len(), 3);
        assert!(store.size() > 0);
        std::fs::remove_dir_all(&folder).expect("cleanup");
    }

    #[test]
    fn series_fill_what_records_cover_and_leave_gaps() {
        let base = 1_000_000_000;
        let records = [record(base + 10_000, 10.0), record(base + 20_000, 20.0), record(base + 50_000, 50.0)];
        let values = series(&records, base, base + 60_000, 6, |record| Some(f64::from(record.cpu)));
        assert_eq!(values, [Some(10.0), Some(20.0), None, None, Some(50.0), None]);
        assert_eq!(at(&records, base + 15_000).map(|record| record.cpu), Some(20.0));
        assert_eq!(at(&records, base + 31_000), None, "a gap");
    }
}
