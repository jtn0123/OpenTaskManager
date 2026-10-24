//! The process table's side of the view: its rows (flat, or grouped by
//! app), the selection, the details panel, and ending what's selected.

use std::time::{SystemTime, UNIX_EPOCH};

use otm_core::actions::{self, Ending};
use otm_core::details;
use otm_core::format::{MISSING, duration};
use otm_core::groups::{self, Line};
use otm_core::model::{ProcessKey, ProcessRow};
use otm_core::rows::{self, Column};
use slint::Model;

use crate::{AppWindow, CloneStrong, Fact, ProcessCells, View};

/// What a table row stands for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pick {
    Process(ProcessKey),
    /// A group's header, by its top process.
    Group(ProcessKey),
}

impl Pick {
    fn key(self) -> ProcessKey {
        match self {
            Pick::Process(key) | Pick::Group(key) => key,
        }
    }
}

/// What End Task or Force Quit acts on, fixed when it's chosen: one process,
/// or a group's members in the order to end them.
pub struct Targets {
    name: String,
    keys: Vec<ProcessKey>,
    group: bool,
}

impl Targets {
    fn question(&self) -> String {
        if self.group {
            actions::group_confirmation(&self.name, self.keys.len())
        } else {
            actions::confirmation(&self.name, self.keys[0])
        }
    }

    /// Ends them, checking each one's identity just before, and says how it went.
    fn end(&self, how: Ending) -> String {
        if self.group {
            let outcome = actions::end_group(&self.keys, how);
            actions::describe_group(&self.name, self.keys.len(), how, &outcome)
        } else {
            let key = self.keys[0];
            actions::describe(&self.name, key, how, &actions::end(key, how))
        }
    }
}

fn cells(row: &ProcessRow, logical_cpus: usize) -> ProcessCells {
    let [name, pid, user, cpu, memory, read, write] = rows::cells(row, logical_cpus);
    ProcessCells {
        name: name.into(),
        pid: pid.into(),
        user: user.into(),
        cpu: cpu.into(),
        memory: memory.into(),
        read: read.into(),
        write: write.into(),
        ..ProcessCells::default()
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

impl View {
    fn row(&self, key: ProcessKey) -> Option<&ProcessRow> {
        self.processes.as_ref()?.iter().find(|row| row.key == key)
    }

    fn group_size(&self, root: ProcessKey) -> usize {
        match (&self.processes, &self.grouping) {
            (Some(processes), Some(grouping)) => processes.iter().filter(|row| grouping.root(row.key) == root).count(),
            _ => 1,
        }
    }

    fn root(&self, key: ProcessKey) -> ProcessKey {
        self.grouping.as_ref().map_or(key, |grouping| grouping.root(key))
    }

    pub(crate) fn draw_table(&mut self, window: &AppWindow) {
        let (column, descending) = self.sort;
        window.set_sort_column(Column::ALL.iter().position(|each| *each == column).unwrap_or(0) as i32);
        window.set_sort_descending(descending);
        window.set_grouped(self.grouped);
        let Some(processes) = &self.processes else {
            window.set_status("Reading processes…".into());
            self.draw_actions(window);
            self.draw_details(window);
            return;
        };
        let cpus = self.logical_cpus;
        let mut picks = Vec::with_capacity(processes.len());
        let mut next = Vec::with_capacity(processes.len());
        match (&self.grouping, self.grouped) {
            (Some(grouping), true) => {
                let lines = groups::arrange(processes, grouping, &self.query, column, descending, cpus, &self.expanded);
                for line in lines {
                    match line {
                        Line::Group { totals, size, expanded } => {
                            picks.push(Pick::Group(totals.key));
                            next.push(ProcessCells {
                                group: true,
                                size: size as i32,
                                expanded,
                                ..cells(&totals, cpus)
                            });
                        }
                        Line::Process { row, indented } => {
                            picks.push(Pick::Process(row.key));
                            next.push(ProcessCells { indented, ..cells(row, cpus) });
                        }
                    }
                }
            }
            _ => {
                for row in rows::arrange(processes, &self.query, column, descending, cpus) {
                    picks.push(Pick::Process(row.key));
                    next.push(cells(row, cpus));
                }
            }
        }
        // A selection out of sight follows its process while it runs: to its
        // group's header when the group is closed, or back to the process when
        // its group is gone. A process that ended takes the selection with it,
        // so End Task never lands on a group nobody picked.
        if let Some(pick) = self.selected
            && !picks.contains(&pick)
        {
            let running = processes.iter().any(|row| row.key == pick.key());
            let root = self.grouping.as_ref().map_or(pick.key(), |grouping| grouping.root(pick.key()));
            self.selected =
                [Pick::Group(root), Pick::Process(pick.key())].into_iter().find(|each| running && picks.contains(each));
        }
        for (pick, cells) in picks.iter().zip(next.iter_mut()) {
            cells.selected = self.selected == Some(*pick);
        }
        self.shown = picks;
        if self.rows.row_count() == next.len() {
            for (index, cells) in next.into_iter().enumerate() {
                if self.rows.row_data(index).as_ref() != Some(&cells) {
                    self.rows.set_row_data(index, cells);
                }
            }
        } else {
            self.rows.set_vec(next);
        }
        let matched = processes.iter().filter(|row| rows::matches(row, &self.query)).count();
        let count = if matched == processes.len() {
            format!("{} processes", processes.len())
        } else {
            format!("Showing {matched} of {} processes", processes.len())
        };
        window.set_status(
            format!("{count} · CPU as a share of all {cpus} CPUs · “—” means the system didn't say").into(),
        );
        self.draw_actions(window);
        self.draw_details(window);
    }

    pub(crate) fn draw_actions(&self, window: &AppWindow) {
        window.set_has_selection(self.selected.is_some());
        window.set_confirm_text(self.pending.as_ref().map(Targets::question).unwrap_or_default().into());
        window.set_notice(self.notice.as_str().into());
    }

    /// The panel under the table. Program and command line are read once per
    /// selection; the rest comes from the latest sample.
    fn draw_details(&mut self, window: &AppWindow) {
        let Some(pick) = self.selected else {
            window.set_details_title("".into());
            return;
        };
        let key = pick.key();
        if self.details.as_ref().map(|(read, _)| *read) != Some(key) {
            self.details = Some((key, details::read(key)));
        }
        let Some(row) = self.row(key) else {
            window.set_details_title("".into());
            return;
        };
        let read = self.details.as_ref().and_then(|(_, details)| details.as_ref());
        let size = self.group_size(self.root(key));
        let title = match pick {
            Pick::Group(_) => format!("{} · group of {size} processes", row.name),
            Pick::Process(_) => format!("{} · PID {}", row.name, key.pid),
        };
        let started_by = row
            .parent
            .and_then(|parent| self.processes.as_ref()?.iter().find(|each| each.key.pid == parent))
            .filter(|parent| parent.key.start_time <= key.start_time)
            .map_or_else(|| MISSING.to_owned(), |parent| format!("{} (PID {})", parent.name, parent.key.pid));
        let mut facts = vec![
            ("Program", read.and_then(|details| details.path.clone()).unwrap_or_else(|| MISSING.to_owned())),
            ("Command line", read.and_then(|details| details.command.clone()).unwrap_or_else(|| MISSING.to_owned())),
            ("Started by", started_by),
            ("Running for", duration(now().saturating_sub(key.start_time))),
            ("User", row.user.clone().unwrap_or_else(|| MISSING.to_owned())),
        ];
        if self.grouped && size > 1 {
            let root = self.root(key);
            let top =
                self.row(root).map_or_else(|| MISSING.to_owned(), |top| format!("{} (PID {})", top.name, root.pid));
            facts.push(("Group", format!("{size} processes, under {top}")));
        }
        window.set_details_title(title.into());
        let facts: Vec<Fact> =
            facts.into_iter().map(|(label, value)| Fact { label: label.into(), value: value.into() }).collect();
        if self.facts.row_count() == facts.len() {
            for (index, fact) in facts.into_iter().enumerate() {
                if self.facts.row_data(index).as_ref() != Some(&fact) {
                    self.facts.set_row_data(index, fact);
                }
            }
        } else {
            self.facts.set_vec(facts);
        }
    }

    /// The selection as targets to end: a group's members ordered for `how`.
    fn targets(&self, how: Ending) -> Option<Targets> {
        let pick = self.selected?;
        let row = self.row(pick.key())?;
        match (pick, &self.grouping, &self.processes) {
            (Pick::Group(root), Some(grouping), Some(processes)) => Some(Targets {
                name: row.name.clone(),
                keys: grouping.ending_order(processes, root, how == Ending::Ask),
                group: true,
            }),
            _ => Some(Targets { name: row.name.clone(), keys: vec![pick.key()], group: false }),
        }
    }

    pub(crate) fn end_task(&mut self) {
        if let Some(targets) = self.targets(Ending::Ask) {
            self.pending = None;
            self.notice = targets.end(Ending::Ask);
        }
        self.redraw_table();
    }

    pub(crate) fn ask_force_quit(&mut self) {
        if let Some(targets) = self.targets(Ending::Force) {
            self.pending = Some(targets);
        }
        self.redraw_table();
    }

    pub(crate) fn force_quit(&mut self) {
        if let Some(targets) = self.pending.take() {
            self.notice = targets.end(Ending::Force);
        }
        self.redraw_table();
    }

    /// Esc: cancels Force Quit's question, else clears the notice, else the selection.
    pub(crate) fn escape(&mut self) {
        if self.pending.take().is_none() {
            if self.notice.is_empty() {
                self.selected = None;
            } else {
                self.notice.clear();
            }
        }
        self.redraw_table();
    }

    pub(crate) fn click_row(&mut self, index: i32) {
        self.selected = usize::try_from(index).ok().and_then(|index| self.shown.get(index).copied());
        self.redraw_table();
    }

    /// Moves the selection `delta` rows and keeps it on screen.
    pub(crate) fn move_selection(&mut self, delta: i32) {
        let Some(last) = self.shown.len().checked_sub(1) else { return };
        let current = self.selected.and_then(|pick| self.shown.iter().position(|shown| *shown == pick));
        let next = match current {
            Some(index) => index.saturating_add_signed(delta as isize).min(last),
            None => 0,
        };
        self.selected = Some(self.shown[next]);
        self.redraw_table();
        self.reveal_selection();
    }

    fn reveal_selection(&self) {
        let index = self.selected.and_then(|pick| self.shown.iter().position(|shown| *shown == pick));
        if let (Some(index), Some(window)) = (index, self.window.clone_strong()) {
            window.invoke_reveal_row(index as i32);
        }
    }

    /// Opens or closes the group whose header is at `index`.
    pub(crate) fn toggle_group(&mut self, index: i32) {
        if let Some(Pick::Group(root)) = usize::try_from(index).ok().and_then(|index| self.shown.get(index).copied()) {
            let open = !self.expanded.contains(&root);
            self.open_group(root, open);
        }
    }

    pub(crate) fn expand_group(&mut self, index: i32) {
        if let Some(Pick::Group(root)) = usize::try_from(index).ok().and_then(|index| self.shown.get(index).copied()) {
            self.open_group(root, true);
        }
    }

    /// Right opens the selected group; Left closes it, or the group the selected member is in.
    pub(crate) fn expand_selection(&mut self, open: bool) {
        match self.selected {
            Some(Pick::Group(root)) => self.open_group(root, open),
            Some(Pick::Process(key)) if !open && self.grouped => {
                let root = self.root(key);
                if self.expanded.contains(&root) {
                    self.open_group(root, false);
                }
            }
            _ => {}
        }
    }

    fn open_group(&mut self, root: ProcessKey, open: bool) {
        if open {
            self.expanded.insert(root);
        } else {
            self.expanded.remove(&root);
            if self.selected.is_some_and(|pick| self.root(pick.key()) == root) {
                self.selected = Some(Pick::Group(root));
            }
        }
        self.redraw_table();
        self.reveal_selection();
    }

    pub(crate) fn set_grouped(&mut self, grouped: bool) {
        self.grouped = grouped;
        if !grouped && let Some(Pick::Group(root)) = self.selected {
            self.selected = Some(Pick::Process(root));
        }
        self.save_settings();
        self.redraw_table();
        self.reveal_selection();
    }
}
