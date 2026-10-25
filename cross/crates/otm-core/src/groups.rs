//! Processes grouped by app: each process sits under its parent, unless the
//! parent is a launcher (the shell, the service manager, systemd), which
//! starts apps without being part of them. A group is a top process and
//! everything under it, so a browser's helpers sit with the browser and a
//! terminal's shells with the terminal.
//!
//! A parent only counts if it started no later than the process naming it,
//! so a PID the system reused never collects an ended app's helpers.

use std::collections::{HashMap, HashSet};

use crate::model::{ProcessKey, ProcessRow};
use crate::rows::{Column, compare, matches};

/// Processes that start apps for the user or the system without being part of them.
const LAUNCHERS: &[&str] = &[
    // Windows
    "system",
    "smss.exe",
    "csrss.exe",
    "wininit.exe",
    "winlogon.exe",
    "services.exe",
    "lsass.exe",
    "svchost.exe",
    "userinit.exe",
    "explorer.exe",
    "sihost.exe",
    "taskhostw.exe",
    "taskeng.exe",
    // Linux: init, session and service managers, desktop shells and launchers
    "init",
    "systemd",
    "kthreadd",
    "login",
    "sshd",
    "dbus-daemon",
    "dbus-broker",
    "gdm",
    "gdm-session-worker",
    "lightdm",
    "sddm",
    "sddm-helper",
    "gnome-session-binary",
    "gnome-shell",
    "plasmashell",
    "ksmserver",
    "kwin_wayland",
    "kwin_x11",
    "krunner",
    "startplasma-wayland",
    "startplasma-x11",
    "xfce4-session",
    "xfce4-panel",
    "lxsession",
    "cinnamon-session",
    "mate-session",
    "budgie-panel",
];

pub fn is_launcher(name: &str) -> bool {
    let name = name.to_lowercase();
    LAUNCHERS.contains(&name.as_str())
}

/// Each process's group root and its distance below it.
pub struct Grouping {
    roots: HashMap<ProcessKey, (ProcessKey, usize)>,
}

impl Grouping {
    pub fn new(rows: &[ProcessRow]) -> Self {
        let by_pid: HashMap<u32, &ProcessRow> = rows.iter().map(|row| (row.key.pid, row)).collect();
        let parent_of = |row: &ProcessRow| {
            let parent = by_pid.get(&row.parent?)?;
            let real = parent.key.pid != row.key.pid
                && parent.key.pid > 1
                && parent.key.start_time <= row.key.start_time
                && !is_launcher(&parent.name);
            real.then_some(*parent)
        };
        let mut roots = HashMap::with_capacity(rows.len());
        for row in rows {
            let (mut top, mut depth) = (row, 0);
            // Chains are short; the limit only guards against a loop in what the system reported.
            while depth < 64
                && let Some(parent) = parent_of(top)
            {
                top = parent;
                depth += 1;
            }
            roots.insert(row.key, (top.key, depth));
        }
        Self { roots }
    }

    /// The top of `key`'s group (itself, for a process alone).
    pub fn root(&self, key: ProcessKey) -> ProcessKey {
        self.roots.get(&key).map_or(key, |(root, _)| *root)
    }

    fn depth(&self, key: ProcessKey) -> usize {
        self.roots.get(&key).map_or(0, |(_, depth)| *depth)
    }

    /// The group of `root`, in the order to end it: for Force Quit the
    /// furthest below first, so no parent outlives its children long enough
    /// to start more; for End Task the top first, so an app can close its
    /// own helpers as it quits.
    pub fn ending_order(&self, rows: &[ProcessRow], root: ProcessKey, top_first: bool) -> Vec<ProcessKey> {
        let mut members: Vec<ProcessKey> =
            rows.iter().map(|row| row.key).filter(|key| self.root(*key) == root).collect();
        members.sort_by(|a, b| {
            let order = self.depth(*a).cmp(&self.depth(*b)).then(a.pid.cmp(&b.pid));
            if top_first { order } else { order.reverse() }
        });
        members
    }
}

/// One line of the grouped table.
#[derive(Debug, PartialEq)]
pub enum Line<'a> {
    /// A group's header: its figures summed over every member, named and
    /// keyed by its top process.
    Group { totals: ProcessRow, size: usize, expanded: bool },
    /// A process: alone, or `indented` under its group's header.
    Process { row: &'a ProcessRow, indented: bool },
}

/// Sums what's known: a figure no member reported stays unknown.
fn sum<T: Copy + std::iter::Sum>(values: impl Iterator<Item = Option<T>>) -> Option<T> {
    let known: Vec<T> = values.flatten().collect();
    (!known.is_empty()).then(|| known.into_iter().sum())
}

fn totals(root: &ProcessRow, members: &[&ProcessRow]) -> ProcessRow {
    ProcessRow {
        cpu: sum(members.iter().map(|row| row.cpu)),
        // Engines are shared, so members' shares can't add up past the whole GPU.
        gpu: sum(members.iter().map(|row| row.gpu)).map(|share| share.min(100.0)),
        memory: sum(members.iter().map(|row| row.memory)),
        disk_read: sum(members.iter().map(|row| row.disk_read)),
        disk_write: sum(members.iter().map(|row| row.disk_write)),
        ..root.clone()
    }
}

/// The grouped table: groups with any process matching `query`, and
/// processes alone, sorted together by `column` (a group by its totals);
/// under each expanded header its members, sorted the same way. While
/// searching, groups open by themselves to show which members matched.
pub fn arrange<'a>(
    rows: &'a [ProcessRow],
    grouping: &Grouping,
    query: &str,
    column: Column,
    descending: bool,
    logical_cpus: usize,
    expanded: &HashSet<ProcessKey>,
) -> Vec<Line<'a>> {
    let by_key: HashMap<ProcessKey, &ProcessRow> = rows.iter().map(|row| (row.key, row)).collect();
    let mut groups: HashMap<ProcessKey, Vec<&ProcessRow>> = HashMap::new();
    for row in rows {
        groups.entry(grouping.root(row.key)).or_default().push(row);
    }
    let searching = !query.trim().is_empty();
    struct Top<'a> {
        row: ProcessRow,
        members: Vec<&'a ProcessRow>,
        size: usize,
        expanded: bool,
        alone: Option<&'a ProcessRow>,
    }
    let mut tops: Vec<Top> = Vec::new();
    for (root, members) in groups {
        let Some(root_row) = by_key.get(&root) else { continue };
        let matched: Vec<&ProcessRow> = members.iter().copied().filter(|row| matches(row, query)).collect();
        if matched.is_empty() {
            continue;
        }
        if members.len() == 1 {
            tops.push(Top {
                row: (*root_row).clone(),
                members: Vec::new(),
                size: 1,
                expanded: false,
                alone: Some(root_row),
            });
            continue;
        }
        let open = expanded.contains(&root) || searching;
        let shown = if searching { matched } else { members.clone() };
        tops.push(Top {
            row: totals(root_row, &members),
            members: shown,
            size: members.len(),
            expanded: open,
            alone: None,
        });
    }
    let order = |a: &ProcessRow, b: &ProcessRow| compare(a, b, column, descending, logical_cpus);
    tops.sort_by(|a, b| order(&a.row, &b.row));
    let mut lines = Vec::with_capacity(rows.len());
    for mut top in tops {
        if let Some(row) = top.alone {
            lines.push(Line::Process { row, indented: false });
            continue;
        }
        lines.push(Line::Group { totals: top.row, size: top.size, expanded: top.expanded });
        if top.expanded {
            top.members.sort_by(|a, b| order(a, b));
            lines.extend(top.members.into_iter().map(|row| Line::Process { row, indented: true }));
        }
    }
    lines
}

/// Orders lines' keys for tests and callers that only need who is where.
pub fn keys(lines: &[Line]) -> Vec<(ProcessKey, bool)> {
    lines
        .iter()
        .map(|line| match line {
            Line::Group { totals, .. } => (totals.key, true),
            Line::Process { row, .. } => (row.key, false),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{Grouping, Line, arrange, is_launcher, keys};
    use crate::model::{ProcessKey, ProcessRow};
    use crate::rows::Column;

    fn row(pid: u32, parent: Option<u32>, start: u64, name: &str, cpu: Option<f32>) -> ProcessRow {
        ProcessRow {
            key: ProcessKey { pid, start_time: start },
            parent,
            name: name.to_owned(),
            user: Some("justin".to_owned()),
            cpu,
            gpu: None,
            memory: Some(u64::from(pid) * 1000),
            disk_read: None,
            disk_write: None,
        }
    }

    /// explorer starts chrome, which starts two helpers; one helper starts
    /// another. A shell started by explorer runs alone.
    fn desktop() -> Vec<ProcessRow> {
        vec![
            row(10, None, 100, "explorer.exe", Some(1.0)),
            row(20, Some(10), 200, "chrome.exe", Some(5.0)),
            row(21, Some(20), 201, "chrome.exe", Some(10.0)),
            row(22, Some(20), 202, "chrome.exe", None),
            row(23, Some(22), 203, "chrome.exe", Some(1.0)),
            row(30, Some(10), 300, "pwsh.exe", Some(2.0)),
        ]
    }

    fn key(pid: u32, start_time: u64) -> ProcessKey {
        ProcessKey { pid, start_time }
    }

    #[test]
    fn helpers_sit_under_their_app_and_launchers_stand_alone() {
        let rows = desktop();
        let grouping = Grouping::new(&rows);
        assert_eq!(grouping.root(key(23, 203)), key(20, 200));
        assert_eq!(grouping.root(key(21, 201)), key(20, 200));
        assert_eq!(grouping.root(key(30, 300)), key(30, 300), "explorer is a launcher, not an app's top");
        assert_eq!(grouping.root(key(10, 100)), key(10, 100));
        assert!(is_launcher("Explorer.EXE"));
        assert!(!is_launcher("chrome.exe"));
    }

    #[test]
    fn a_parent_started_later_is_a_reused_pid_not_a_parent() {
        let rows = vec![row(5, None, 500, "new.exe", None), row(6, Some(5), 400, "orphan.exe", None)];
        let grouping = Grouping::new(&rows);
        assert_eq!(grouping.root(key(6, 400)), key(6, 400));
    }

    #[test]
    fn groups_sort_by_their_totals_and_open_to_their_members() {
        let rows = desktop();
        let grouping = Grouping::new(&rows);
        let collapsed = arrange(&rows, &grouping, "", Column::Cpu, true, 1, &HashSet::new());
        assert_eq!(keys(&collapsed), [(key(20, 200), true), (key(30, 300), false), (key(10, 100), false)]);
        let Line::Group { totals, size, expanded } = &collapsed[0] else { panic!("a group first") };
        assert_eq!((totals.cpu, totals.memory, *size, *expanded), (Some(16.0), Some(86_000), 4, false));
        assert_eq!(totals.disk_read, None, "nothing known stays unknown");

        let open = arrange(&rows, &grouping, "", Column::Cpu, true, 1, &HashSet::from([key(20, 200)]));
        let pids: Vec<u32> = keys(&open).iter().map(|(key, _)| key.pid).collect();
        assert_eq!(pids, [20, 21, 20, 23, 22, 30, 10], "members by CPU, the unknown last");
    }

    #[test]
    fn a_search_keeps_groups_with_a_match_and_shows_which_members_matched() {
        let mut rows = desktop();
        rows[3].name = "chrome-gpu.exe".to_owned();
        let grouping = Grouping::new(&rows);
        let found = arrange(&rows, &grouping, "gpu", Column::Name, false, 1, &HashSet::new());
        assert_eq!(keys(&found), [(key(20, 200), true), (key(22, 202), false)]);
        let Line::Group { size, .. } = &found[0] else { panic!("the group") };
        assert_eq!(*size, 4, "the header still sums the whole group");
    }

    #[test]
    fn ends_from_the_bottom_for_force_and_from_the_top_when_asking() {
        let rows = desktop();
        let grouping = Grouping::new(&rows);
        let pids = |keys: Vec<ProcessKey>| keys.into_iter().map(|key| key.pid).collect::<Vec<_>>();
        assert_eq!(pids(grouping.ending_order(&rows, key(20, 200), false)), [23, 22, 21, 20]);
        assert_eq!(pids(grouping.ending_order(&rows, key(20, 200), true)), [20, 21, 22, 23]);
    }
}
