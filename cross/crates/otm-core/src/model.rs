//! What one sample holds. A figure the system didn't give is `None`, shown
//! as "—", never zero.

/// A process is its PID and start time, so a PID the system reuses never
/// inherits another process's figures or selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ProcessKey {
    pub pid: u32,
    /// Seconds since the Unix epoch.
    pub start_time: u64,
}

/// One process over one sampling interval.
#[derive(Clone, Debug, PartialEq)]
pub struct ProcessRow {
    pub key: ProcessKey,
    /// The PID of the process that started it, when the system says.
    pub parent: Option<u32>,
    pub name: String,
    /// None when the account can't be named.
    pub user: Option<String>,
    /// Percent of one logical CPU (100 = one CPU busy for the whole
    /// interval), as Activity Monitor counts it; the interface shows it as a
    /// share of the whole machine. None the first time a process is seen,
    /// before there is an interval to measure.
    pub cpu: Option<f32>,
    /// Resident memory in bytes, or None for a process the system won't let
    /// this account open (Windows' protected and system processes).
    pub memory: Option<u64>,
    /// Bytes per second, or None where the system won't say (another
    /// account's process without administrator rights, or a first sighting).
    pub disk_read: Option<f64>,
    pub disk_write: Option<f64>,
}

/// Bytes per second read from and written to the physical disks.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiskRates {
    pub read: f64,
    pub write: f64,
}

/// Bytes per second over every interface except loopback.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NetworkRates {
    pub received: f64,
    pub sent: f64,
}

/// The whole machine over one sampling interval.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    /// Milliseconds since the Unix epoch when the interval ended.
    pub time_ms: u64,
    /// Seconds the interval covered.
    pub interval: f64,
    /// Busy share of the whole CPU, 0–100.
    pub cpu: f32,
    /// Busy share of each logical CPU, 0–100.
    pub cores: Vec<f32>,
    pub memory_used: u64,
    pub memory_total: u64,
    pub swap_used: u64,
    pub swap_total: u64,
    /// None when no disk reports its traffic.
    pub disk: Option<DiskRates>,
    /// None when no interface other than loopback is listed.
    pub network: Option<NetworkRates>,
}
