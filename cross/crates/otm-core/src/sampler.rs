//! Reads the machine and its processes once per interval through `sysinfo`,
//! which covers Linux, Windows and macOS. Rates need two readings, so the
//! first one after a pause only primes the counters: nothing is reported
//! from it rather than a zero the system never measured.

use std::collections::HashSet;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use sysinfo::{
    CpuRefreshKind, DiskRefreshKind, Disks, MemoryRefreshKind, Networks, Process, ProcessRefreshKind,
    ProcessesToUpdate, System, ThreadKind, Uid, UpdateKind, Users,
};

use crate::model::{DiskRates, NetworkRates, ProcessKey, ProcessRow, Snapshot};

pub struct Sampler {
    system: System,
    disks: Disks,
    networks: Networks,
    users: Users,
    /// When the previous reading was taken.
    last: Option<Instant>,
    /// The processes seen at the previous reading, or None when processes
    /// weren't read then and their counters need priming again.
    seen: Option<HashSet<ProcessKey>>,
    me: Option<Uid>,
    superuser: bool,
}

impl Default for Sampler {
    fn default() -> Self {
        Self::new()
    }
}

impl Sampler {
    pub fn new() -> Self {
        let mut system = System::new();
        let me = sysinfo::get_current_pid().ok().and_then(|pid| {
            system.refresh_processes_specifics(
                ProcessesToUpdate::Some(&[pid]),
                false,
                ProcessRefreshKind::nothing().with_user(UpdateKind::Always),
            );
            system.process(pid).and_then(|process| process.user_id().cloned())
        });
        let superuser = me.as_ref().is_some_and(is_superuser);
        system.refresh_cpu_specifics(CpuRefreshKind::nothing().with_cpu_usage());
        Self {
            system,
            disks: Disks::new_with_refreshed_list_specifics(DiskRefreshKind::nothing().with_io_usage()),
            networks: Networks::new_with_refreshed_list(),
            users: Users::new_with_refreshed_list(),
            last: None,
            seen: None,
            me,
            superuser,
        }
    }

    pub fn logical_cpus(&self) -> usize {
        self.system.cpus().len()
    }

    /// Reads the machine, and its processes when `with_processes` is set.
    /// Returns None from the very first call, which only primes the
    /// counters. The process list is None on the first interval processes
    /// are read after a pause, for the same reason.
    pub fn sample(&mut self, with_processes: bool) -> Option<(Snapshot, Option<Vec<ProcessRow>>)> {
        let now = Instant::now();
        let previous = self.last.replace(now);
        self.system.refresh_cpu_specifics(CpuRefreshKind::nothing().with_cpu_usage());
        self.system.refresh_memory_specifics(MemoryRefreshKind::nothing().with_ram().with_swap());
        self.disks.refresh_specifics(true, DiskRefreshKind::nothing().with_io_usage());
        self.networks.refresh(true);
        let interval = previous.map(|previous| now.duration_since(previous).as_secs_f64());
        let processes = if with_processes {
            self.system.refresh_processes_specifics(
                ProcessesToUpdate::All,
                true,
                ProcessRefreshKind::nothing()
                    .with_cpu()
                    .with_memory()
                    .with_disk_usage()
                    .with_user(UpdateKind::OnlyIfNotSet)
                    .with_cmd(UpdateKind::OnlyIfNotSet)
                    // Threads aren't processes; Linux would otherwise list each one.
                    .without_tasks(),
            );
            let seen = self.seen.take();
            let rows = match (seen, interval) {
                (Some(seen), Some(interval)) => Some(self.rows(&seen, interval)),
                _ => None,
            };
            self.seen = Some(self.keys());
            rows
        } else {
            self.seen = None;
            None
        };
        let interval = interval?;
        Some((self.snapshot(interval), processes))
    }

    fn snapshot(&self, interval: f64) -> Snapshot {
        let time_ms = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64);
        Snapshot {
            time_ms,
            interval,
            cpu: self.system.global_cpu_usage(),
            cores: self.system.cpus().iter().map(|cpu| cpu.cpu_usage()).collect(),
            memory_used: self.system.used_memory(),
            memory_total: self.system.total_memory(),
            swap_used: self.system.used_swap(),
            swap_total: self.system.total_swap(),
            disk: self.disk_rates(interval),
            network: self.network_rates(interval),
        }
    }

    /// Each physical disk once, though several volumes may sit on it.
    fn disk_rates(&self, interval: f64) -> Option<DiskRates> {
        let mut names = HashSet::new();
        let (mut read, mut written) = (0u64, 0u64);
        for disk in self.disks.list() {
            if names.insert(disk.name()) {
                let usage = disk.usage();
                read += usage.read_bytes;
                written += usage.written_bytes;
            }
        }
        (!names.is_empty()).then(|| DiskRates { read: read as f64 / interval, write: written as f64 / interval })
    }

    fn network_rates(&self, interval: f64) -> Option<NetworkRates> {
        let mut listed = false;
        let (mut received, mut sent) = (0u64, 0u64);
        for (name, data) in self.networks.list() {
            if is_loopback(name) {
                continue;
            }
            listed = true;
            received += data.received();
            sent += data.transmitted();
        }
        listed.then(|| NetworkRates { received: received as f64 / interval, sent: sent as f64 / interval })
    }

    /// Processes, not their threads (which Linux lists alongside them).
    fn processes(&self) -> impl Iterator<Item = &Process> {
        self.system.processes().values().filter(|process| process.thread_kind() != Some(ThreadKind::Userland))
    }

    fn keys(&self) -> HashSet<ProcessKey> {
        self.processes().map(|process| key(process.pid(), process.start_time())).collect()
    }

    fn rows(&self, seen: &HashSet<ProcessKey>, interval: f64) -> Vec<ProcessRow> {
        self.processes()
            .map(|process| {
                let key = key(process.pid(), process.start_time());
                let measured = seen.contains(&key);
                // Other accounts' I/O counters are private; the system reports them as zero.
                let readable = self.superuser || (self.me.is_some() && process.user_id() == self.me.as_ref());
                let usage = process.disk_usage();
                let rate = |bytes: u64| (measured && readable).then(|| bytes as f64 / interval);
                let unopened = could_not_open(process.memory());
                ProcessRow {
                    key,
                    parent: process.parent().map(sysinfo::Pid::as_u32),
                    name: full_name(
                        &process.name().to_string_lossy(),
                        process.cmd().first().map(|argument| argument.to_string_lossy()).as_deref(),
                    ),
                    user: process
                        .user_id()
                        .and_then(|uid| self.users.get_user_by_id(uid))
                        .map(|user| user.name().to_owned()),
                    cpu: (measured && !unopened).then(|| process.cpu_usage()),
                    memory: (!unopened).then(|| process.memory()),
                    disk_read: rate(usage.read_bytes),
                    disk_write: rate(usage.written_bytes),
                }
            })
            .collect()
    }
}

/// Windows won't let an ordinary account open protected and system
/// processes (System, csrss, services and the like), and they come back with
/// no memory and no CPU time: unknown, not zero. Elsewhere a process with no
/// resident memory is real (Linux's kernel threads), so this is Windows only.
#[cfg(windows)]
fn could_not_open(resident: u64) -> bool {
    resident == 0
}

#[cfg(not(windows))]
fn could_not_open(_resident: u64) -> bool {
    false
}

fn key(pid: sysinfo::Pid, start_time: u64) -> ProcessKey {
    ProcessKey { pid: pid.as_u32(), start_time }
}

/// Linux keeps only a process name's first 15 bytes; when the command's own
/// first word starts with that, its file name is the whole name.
fn full_name(name: &str, first_argument: Option<&str>) -> String {
    const LINUX_NAME_LIMIT: usize = 15;
    if name.len() >= LINUX_NAME_LIMIT
        && let Some(argument) = first_argument
    {
        let file = argument.rsplit(['/', '\\']).next().unwrap_or(argument);
        if file.len() > name.len() && file.starts_with(name) {
            return file.to_owned();
        }
    }
    name.to_owned()
}

fn is_loopback(name: &str) -> bool {
    name == "lo" || name.starts_with("lo0") || name.contains("Loopback")
}

#[cfg(unix)]
fn is_superuser(uid: &Uid) -> bool {
    **uid == 0
}

#[cfg(not(unix))]
fn is_superuser(_uid: &Uid) -> bool {
    // Windows' administrators still can't read every process; treat no one as all-seeing.
    false
}

#[cfg(test)]
mod tests {
    use super::{Sampler, full_name, is_loopback};
    use std::thread::sleep;
    use std::time::Duration;

    /// Live, on Windows: the processes Windows won't open (System among them)
    /// show their memory as unknown, never as zero bytes.
    #[cfg(windows)]
    #[test]
    fn windows_never_reports_a_process_it_could_not_open_as_zero() {
        let mut sampler = Sampler::new();
        sampler.sample(true);
        sleep(Duration::from_millis(300));
        sampler.sample(true);
        sleep(Duration::from_millis(300));
        let (_, processes) = sampler.sample(true).expect("a snapshot");
        let processes = processes.expect("processes on their second reading");
        assert!(processes.iter().all(|row| row.memory != Some(0)), "no process shows 0 bytes");
        let system = processes.iter().find(|row| row.key.pid == 4).expect("the System process");
        assert_eq!(system.memory, None);
        assert_eq!(system.cpu, None);
    }

    #[test]
    fn names_loopback_interfaces() {
        assert!(is_loopback("lo"));
        assert!(is_loopback("lo0"));
        assert!(is_loopback("Loopback Pseudo-Interface 1"));
        assert!(!is_loopback("eth0"));
        assert!(!is_loopback("wlan0"));
    }

    #[test]
    fn recovers_names_linux_cut_short() {
        assert_eq!(full_name("WebKitWebProces", Some("/usr/lib/webkitgtk/WebKitWebProcess")), "WebKitWebProcess");
        assert_eq!(full_name("WebKitWebProces", Some("WebKitWebProcess")), "WebKitWebProcess");
        assert_eq!(full_name("short", Some("/usr/bin/shorter-name")), "short", "names under the limit are whole");
        assert_eq!(full_name("abcdefghijklmno", Some("/bin/other-program")), "abcdefghijklmno", "a different program");
        assert_eq!(full_name("abcdefghijklmno", None), "abcdefghijklmno");
        assert_eq!(full_name("Windows Program Name", Some("C:\\Program Files\\x.exe")), "Windows Program Name");
        assert_eq!(full_name("WindowsProgramNa", Some("C:\\Apps\\WindowsProgramName.exe")), "WindowsProgramName.exe");
    }

    /// Live: reads this machine, so it checks shapes and priming, not values.
    #[test]
    fn primes_before_reporting_and_measures_processes_only_on_their_second_reading() {
        let mut sampler = Sampler::new();
        assert!(sampler.sample(true).is_none(), "the first reading only primes");
        sleep(Duration::from_millis(300));
        let (snapshot, processes) = sampler.sample(false).expect("a snapshot once primed");
        assert!(processes.is_none(), "processes weren't asked for");
        assert!(snapshot.interval > 0.2);
        assert_eq!(snapshot.cores.len(), sampler.logical_cpus());
        assert!(snapshot.memory_total > 0 && snapshot.memory_used <= snapshot.memory_total);
        assert!((0.0..=100.0).contains(&snapshot.cpu));

        sleep(Duration::from_millis(300));
        let (_, processes) = sampler.sample(true).expect("a snapshot");
        assert!(processes.is_none(), "after a pause, process counters prime again");
        sleep(Duration::from_millis(300));
        let (_, processes) = sampler.sample(true).expect("a snapshot");
        let processes = processes.expect("processes on their second reading");
        let me = std::process::id();
        let own = processes.iter().find(|row| row.key.pid == me).expect("this test's own process");
        assert!(own.cpu.is_some(), "a process seen before has a CPU figure");
        assert!(own.disk_read.is_some(), "this account's own I/O is readable");
        assert!(own.memory.is_some_and(|bytes| bytes > 0));
    }
}
