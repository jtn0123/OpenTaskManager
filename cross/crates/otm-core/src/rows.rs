//! The process table's rules for native interfaces: which rows a search
//! keeps, their order, and each cell's text.

use std::cmp::Ordering;

use crate::format::{MISSING, bytes, percent, rate};
use crate::model::ProcessRow;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Column {
    Name,
    Pid,
    User,
    Cpu,
    Memory,
    DiskRead,
    DiskWrite,
}

impl Column {
    pub const ALL: [Column; 7] =
        [Column::Name, Column::Pid, Column::User, Column::Cpu, Column::Memory, Column::DiskRead, Column::DiskWrite];

    pub fn from_index(index: usize) -> Option<Column> {
        Self::ALL.get(index).copied()
    }

    pub fn title(self) -> &'static str {
        match self {
            Column::Name => "Name",
            Column::Pid => "PID",
            Column::User => "User",
            Column::Cpu => "CPU",
            Column::Memory => "Memory",
            Column::DiskRead => "Disk read",
            Column::DiskWrite => "Disk write",
        }
    }

    /// The column's name in the settings file, which never changes.
    pub fn key(self) -> &'static str {
        match self {
            Column::Name => "name",
            Column::Pid => "pid",
            Column::User => "user",
            Column::Cpu => "cpu",
            Column::Memory => "memory",
            Column::DiskRead => "disk-read",
            Column::DiskWrite => "disk-write",
        }
    }

    /// Figures start highest first, text A–Z.
    pub fn numeric(self) -> bool {
        !matches!(self, Column::Name | Column::User)
    }
}

enum Value<'a> {
    Number(f64),
    Text(&'a str),
    Missing,
}

/// CPU as a share of the whole machine: the core reports percent of one CPU.
pub fn machine_share(row: &ProcessRow, logical_cpus: usize) -> Option<f64> {
    row.cpu.map(|cpu| f64::from(cpu) / logical_cpus.max(1) as f64)
}

fn value(row: &ProcessRow, column: Column, logical_cpus: usize) -> Value<'_> {
    let number = |value: Option<f64>| value.map_or(Value::Missing, Value::Number);
    match column {
        Column::Name => Value::Text(&row.name),
        Column::Pid => Value::Number(f64::from(row.key.pid)),
        Column::User => row.user.as_deref().map_or(Value::Missing, Value::Text),
        Column::Cpu => number(machine_share(row, logical_cpus)),
        Column::Memory => number(row.memory.map(|bytes| bytes as f64)),
        Column::DiskRead => number(row.disk_read),
        Column::DiskWrite => number(row.disk_write),
    }
}

/// Whether `row` matches a search: name or user containing it, or a PID starting with it.
pub fn matches(row: &ProcessRow, query: &str) -> bool {
    let query = query.trim().to_lowercase();
    query.is_empty()
        || row.name.to_lowercase().contains(&query)
        || row.key.pid.to_string().starts_with(&query)
        || row.user.as_deref().is_some_and(|user| user.to_lowercase().contains(&query))
}

/// The table's order by `column`. Missing figures sort last either way;
/// ties go by PID, so rows don't swap places between samples.
pub fn compare(a: &ProcessRow, b: &ProcessRow, column: Column, descending: bool, logical_cpus: usize) -> Ordering {
    let order = match (value(a, column, logical_cpus), value(b, column, logical_cpus)) {
        (Value::Missing, Value::Missing) => Ordering::Equal,
        (Value::Missing, _) => return Ordering::Greater,
        (_, Value::Missing) => return Ordering::Less,
        (Value::Number(x), Value::Number(y)) => x.total_cmp(&y),
        (Value::Text(x), Value::Text(y)) => x.to_lowercase().cmp(&y.to_lowercase()),
        (Value::Number(_), Value::Text(_)) => Ordering::Less,
        (Value::Text(_), Value::Number(_)) => Ordering::Greater,
    };
    let order = if descending { order.reverse() } else { order };
    order.then(a.key.pid.cmp(&b.key.pid))
}

/// The rows a search keeps, sorted by `column` (see `compare`).
pub fn arrange<'a>(
    rows: &'a [ProcessRow],
    query: &str,
    column: Column,
    descending: bool,
    logical_cpus: usize,
) -> Vec<&'a ProcessRow> {
    let mut kept: Vec<&ProcessRow> = rows.iter().filter(|row| matches(row, query)).collect();
    kept.sort_by(|a, b| compare(a, b, column, descending, logical_cpus));
    kept
}

/// Each column's text for `row`, in `Column::ALL` order.
pub fn cells(row: &ProcessRow, logical_cpus: usize) -> [String; 7] {
    [
        row.name.clone(),
        row.key.pid.to_string(),
        row.user.clone().unwrap_or_else(|| MISSING.to_owned()),
        percent(machine_share(row, logical_cpus)),
        bytes(row.memory.map(|bytes| bytes as f64)),
        rate(row.disk_read),
        rate(row.disk_write),
    ]
}

#[cfg(test)]
mod tests {
    use super::{Column, arrange, cells, matches};
    use crate::model::{ProcessKey, ProcessRow};

    fn row(pid: u32, name: &str, cpu: Option<f32>, read: Option<f64>) -> ProcessRow {
        ProcessRow {
            key: ProcessKey { pid, start_time: 1 },
            parent: None,
            name: name.to_owned(),
            user: pid.is_multiple_of(2).then(|| "justin".to_owned()),
            cpu,
            memory: Some(u64::from(pid) * 1024),
            disk_read: read,
            disk_write: None,
        }
    }

    fn pids(rows: &[&ProcessRow]) -> Vec<u32> {
        rows.iter().map(|row| row.key.pid).collect()
    }

    #[test]
    fn missing_figures_sort_last_in_both_directions() {
        let rows = [row(1, "a", None, None), row(2, "b", Some(50.0), Some(1.0)), row(3, "c", Some(10.0), Some(9.0))];
        assert_eq!(pids(&arrange(&rows, "", Column::Cpu, true, 1)), [2, 3, 1]);
        assert_eq!(pids(&arrange(&rows, "", Column::Cpu, false, 1)), [3, 2, 1]);
        assert_eq!(pids(&arrange(&rows, "", Column::DiskRead, true, 1)), [3, 2, 1]);
    }

    #[test]
    fn ties_keep_pid_order_and_text_ignores_case() {
        let rows = [row(9, "b", Some(5.0), None), row(4, "B", Some(5.0), None), row(7, "a", Some(5.0), None)];
        assert_eq!(pids(&arrange(&rows, "", Column::Cpu, true, 1)), [4, 7, 9]);
        assert_eq!(pids(&arrange(&rows, "", Column::Name, false, 1)), [7, 4, 9]);
    }

    #[test]
    fn searches_name_user_and_pid_prefix() {
        let firefox = row(4120, "Firefox", None, None);
        assert!(matches(&firefox, "fire"));
        assert!(matches(&firefox, "412"));
        assert!(!matches(&firefox, "120"));
        assert!(matches(&firefox, "JUSTIN"));
        assert!(matches(&firefox, "  "));
    }

    #[test]
    fn cells_show_a_dash_where_figures_are_missing_and_cpu_as_a_machine_share() {
        let text = cells(&row(3, "c", Some(400.0), None), 16);
        assert_eq!(text[2], "—", "an account that can't be named");
        assert_eq!(text[3], "25%", "400% of one CPU is a quarter of sixteen");
        assert_eq!(text[5], "—");
    }
}
