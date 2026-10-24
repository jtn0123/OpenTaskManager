//! What one sample holds, as the interface receives it. A figure the system
//! didn't give is `None`, shown as "—", never zero.

use serde::Serialize;
use ts_rs::TS;

/// A process is its PID and start time, so a PID the system reuses never
/// inherits another process's figures or selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export)]
pub struct ProcessKey {
    pub pid: u32,
    /// Seconds since the Unix epoch.
    #[ts(type = "number")]
    pub start_time: u64,
}

/// One process over one sampling interval.
#[derive(Clone, Debug, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export)]
pub struct ProcessRow {
    pub key: ProcessKey,
    pub name: String,
    /// None when the account can't be named.
    pub user: Option<String>,
    /// Percent of one logical CPU (100 = one CPU busy for the whole
    /// interval), as Activity Monitor counts it; the interface shows it as a
    /// share of the whole machine. None the first time a process is seen,
    /// before there is an interval to measure.
    pub cpu: Option<f32>,
    /// Resident memory in bytes.
    #[ts(type = "number")]
    pub memory: u64,
    /// Bytes per second, or None where the system won't say (another
    /// account's process without administrator rights, or a first sighting).
    pub disk_read: Option<f64>,
    pub disk_write: Option<f64>,
}

/// Bytes per second read from and written to the physical disks.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, TS)]
#[ts(export)]
pub struct DiskRates {
    pub read: f64,
    pub write: f64,
}

/// Bytes per second over every interface except loopback.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, TS)]
#[ts(export)]
pub struct NetworkRates {
    pub received: f64,
    pub sent: f64,
}

/// The whole machine over one sampling interval.
#[derive(Clone, Debug, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export)]
pub struct Snapshot {
    /// Milliseconds since the Unix epoch when the interval ended.
    #[ts(type = "number")]
    pub time_ms: u64,
    /// Seconds the interval covered.
    pub interval: f64,
    /// Busy share of the whole CPU, 0–100.
    pub cpu: f32,
    /// Busy share of each logical CPU, 0–100.
    pub cores: Vec<f32>,
    #[ts(type = "number")]
    pub memory_used: u64,
    #[ts(type = "number")]
    pub memory_total: u64,
    #[ts(type = "number")]
    pub swap_used: u64,
    #[ts(type = "number")]
    pub swap_total: u64,
    /// None when no disk reports its traffic.
    pub disk: Option<DiskRates>,
    /// None when no interface other than loopback is listed.
    pub network: Option<NetworkRates>,
}

/// The top of each rate graph's axis, in bytes per second.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, TS)]
#[ts(export)]
pub struct Scales {
    pub disk: f64,
    pub network: f64,
}

/// What the interface receives each interval while its window is open.
#[derive(Clone, Debug, PartialEq, Serialize, TS)]
#[ts(export)]
pub struct Tick {
    pub snapshot: Snapshot,
    /// None while process sampling restarts (the first interval after the
    /// window opens), so a row never shows a rate measured over a gap.
    pub processes: Option<Vec<ProcessRow>>,
    pub scales: Scales,
}

/// Everything recorded so far, for a window that has just opened.
#[derive(Clone, Debug, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export)]
pub struct HistoryReply {
    pub snapshots: Vec<Snapshot>,
    pub scales: Scales,
    pub logical_cpus: u32,
    /// How many snapshots the graphs span.
    pub capacity: u32,
    /// Seconds between samples.
    pub interval: f64,
    /// Whether graphs slide between samples, when chosen at launch
    /// (`--slide-graphs` or `--step-graphs`); None lets the interface decide.
    pub slide_graphs: Option<bool>,
}
