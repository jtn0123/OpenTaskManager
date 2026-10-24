//! OpenTaskManager for Windows and Linux, drawn natively with Slint on the
//! shared Rust core. The window exists only while it's open; closing it
//! drops it, and the tray keeps sampling.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod graph;
mod tray;

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use otm_core::format::{MISSING, axis_rate, bytes, percent, rate};
use otm_core::history::Ring;
use otm_core::model::{ProcessKey, ProcessRow, Snapshot};
use otm_core::rows::{self, Column};
use otm_core::sampler::Sampler;
use otm_core::scale::AutoScale;
use slint::{CloseRequestResponse, ComponentHandle, Model, ModelRc, VecModel};

slint::include_modules!();

const INTERVAL: Duration = Duration::from_secs(1);
/// Samples the graphs span: a minute at one a second.
const SPAN: usize = 60;

/// Everything the window shows, kept on the UI thread while it's closed too,
/// so it reopens with history.
struct View {
    window: Option<AppWindow>,
    snapshots: Ring<Snapshot>,
    disk: AutoScale,
    network: AutoScale,
    samples: u64,
    logical_cpus: usize,
    processes: Option<Vec<ProcessRow>>,
    sort: (Column, bool),
    query: String,
    /// The table's rows, changed in place so it keeps its scroll position.
    rows: Rc<VecModel<ProcessCells>>,
    /// Rows in the order shown, to map a row index back to its process.
    shown: Vec<ProcessKey>,
    selected: Option<ProcessKey>,
    showing: Arc<AtomicBool>,
}

thread_local! {
    static VIEW: RefCell<Option<View>> = const { RefCell::new(None) };
}

/// Runs `change` on the view. A call made while the view is already in use
/// is skipped: those can only come from Slint answering our own updates.
fn with_view(change: impl FnOnce(&mut View)) {
    VIEW.with(|view| {
        if let Ok(mut view) = view.try_borrow_mut()
            && let Some(view) = view.as_mut()
        {
            change(view);
        }
    });
}

impl View {
    fn series(&self, pick: impl Fn(&Snapshot) -> Option<f64>) -> Vec<Option<f64>> {
        self.snapshots.iter().map(pick).collect()
    }

    fn card(
        &self,
        frame: graph::Frame,
        values: &[Option<f64>],
        second: Option<&[Option<f64>]>,
        top: f64,
        fill: bool,
    ) -> CardData {
        CardData {
            grid: graph::grid(frame, self.samples).into(),
            area: if fill { graph::area(values, top, frame) } else { graph::NOTHING.to_owned() }.into(),
            line: graph::line(values, top, frame).into(),
            dashed: second
                .map_or_else(|| graph::NOTHING.to_owned(), |second| graph::dashed(second, top, frame, self.samples))
                .into(),
            ..CardData::default()
        }
    }

    fn draw_graphs(&self, window: &AppWindow) {
        let frame = graph::Frame {
            width: f64::from(window.get_graph_width()),
            height: f64::from(window.get_graph_height()),
            span: SPAN,
        };
        let latest = self.snapshots.last();
        let cpu = self.series(|s| Some(f64::from(s.cpu)));
        let mut card = self.card(frame, &cpu, None, 100.0, true);
        card.top_label = "100%".into();
        card.value = percent(latest.map(|s| f64::from(s.cpu))).into();
        card.caption = format!("{} logical CPUs", self.logical_cpus).into();
        window.set_cpu(card);

        let memory =
            self.series(|s| (s.memory_total > 0).then(|| s.memory_used as f64 / s.memory_total as f64 * 100.0));
        let mut card = self.card(frame, &memory, None, 100.0, true);
        card.top_label = "100%".into();
        card.value = percent(memory.last().copied().flatten()).into();
        card.caption = latest
            .map(|s| {
                let used = bytes(Some(s.memory_used as f64));
                format!("{used} of {} · swap {}", bytes(Some(s.memory_total as f64)), bytes(Some(s.swap_used as f64)))
            })
            .unwrap_or_default()
            .into();
        window.set_memory(card);

        let (top, read, write) =
            (self.disk.bound(), self.series(|s| s.disk.map(|d| d.read)), self.series(|s| s.disk.map(|d| d.write)));
        let mut card = self.card(frame, &read, Some(&write), top, false);
        card.top_label = axis_rate(top).into();
        let disk = latest.and_then(|s| s.disk);
        card.value = disk.map_or_else(|| MISSING.to_owned(), |d| rate(Some(d.read + d.write))).into();
        card.caption = disk
            .map_or_else(
                || "No disk reported its traffic".to_owned(),
                |d| format!("Read {} · write {} (dashed)", rate(Some(d.read)), rate(Some(d.write))),
            )
            .into();
        window.set_disk(card);

        let top = self.network.bound();
        let (received, sent) =
            (self.series(|s| s.network.map(|n| n.received)), self.series(|s| s.network.map(|n| n.sent)));
        let mut card = self.card(frame, &received, Some(&sent), top, false);
        card.top_label = axis_rate(top).into();
        let network = latest.and_then(|s| s.network);
        card.value = network.map_or_else(|| MISSING.to_owned(), |n| rate(Some(n.received + n.sent))).into();
        card.caption = network
            .map_or_else(
                || "No network interface listed".to_owned(),
                |n| format!("In {} · out {} (dashed)", rate(Some(n.received)), rate(Some(n.sent))),
            )
            .into();
        window.set_network(card);
    }

    fn draw_table(&mut self, window: &AppWindow) {
        let (column, descending) = self.sort;
        window.set_sort_column(Column::ALL.iter().position(|each| *each == column).unwrap_or(0) as i32);
        window.set_sort_descending(descending);
        let Some(processes) = &self.processes else {
            window.set_status(format!("Reading processes… · every {} s", INTERVAL.as_secs()).into());
            return;
        };
        let arranged = rows::arrange(processes, &self.query, column, descending, self.logical_cpus);
        self.shown = arranged.iter().map(|row| row.key).collect();
        if self.selected.is_some_and(|key| !self.shown.contains(&key)) {
            self.selected = None;
        }
        let next: Vec<ProcessCells> = arranged
            .iter()
            .map(|row| {
                let [name, pid, user, cpu, memory, read, write] = rows::cells(row, self.logical_cpus);
                ProcessCells {
                    name: name.into(),
                    pid: pid.into(),
                    user: user.into(),
                    cpu: cpu.into(),
                    memory: memory.into(),
                    read: read.into(),
                    write: write.into(),
                    selected: self.selected == Some(row.key),
                }
            })
            .collect();
        if self.rows.row_count() == next.len() {
            for (index, cells) in next.into_iter().enumerate() {
                if self.rows.row_data(index).as_ref() != Some(&cells) {
                    self.rows.set_row_data(index, cells);
                }
            }
        } else {
            self.rows.set_vec(next);
        }
        let count = if self.shown.len() == processes.len() {
            format!("{} processes", processes.len())
        } else {
            format!("Showing {} of {} processes", self.shown.len(), processes.len())
        };
        window.set_status(
            format!(
                "{count} · every {} s · CPU as a share of all {} CPUs · “—” means the system didn't say",
                INTERVAL.as_secs(),
                self.logical_cpus
            )
            .into(),
        );
    }

    fn redraw(&mut self) {
        if let Some(window) = self.window.clone_strong() {
            self.draw_graphs(&window);
            self.draw_table(&window);
        }
    }

    fn redraw_table(&mut self) {
        if let Some(window) = self.window.clone_strong() {
            self.draw_table(&window);
        }
    }

    /// Moves the selection `delta` rows and keeps it on screen.
    fn move_selection(&mut self, delta: i32) {
        let Some(last) = self.shown.len().checked_sub(1) else { return };
        let current = self.selected.and_then(|key| self.shown.iter().position(|shown| *shown == key));
        let next = match current {
            Some(index) => index.saturating_add_signed(delta as isize).min(last),
            None => 0,
        };
        self.selected = Some(self.shown[next]);
        self.redraw_table();
        if let Some(window) = self.window.clone_strong() {
            window.invoke_reveal_row(next as i32);
        }
    }

    fn take_sample(&mut self, snapshot: Snapshot, processes: Option<Vec<ProcessRow>>) {
        self.logical_cpus = snapshot.cores.len().max(1);
        self.snapshots.push(snapshot);
        self.samples += 1;
        let (mut disk, mut network) = (0f64, 0f64);
        for s in self.snapshots.iter() {
            if let Some(d) = s.disk {
                disk = disk.max(d.read).max(d.write);
            }
            if let Some(n) = s.network {
                network = network.max(n.received).max(n.sent);
            }
        }
        self.disk.update(disk);
        self.network.update(network);
        let Some(window) = self.window.clone_strong() else { return };
        let visible = window.window().is_visible() && !window.window().is_minimized();
        self.showing.store(visible, Ordering::Relaxed);
        if !visible {
            return;
        }
        self.draw_graphs(&window);
        if processes.is_some() {
            self.processes = processes;
            self.draw_table(&window);
        }
    }
}

trait CloneStrong {
    fn clone_strong(&self) -> Option<AppWindow>;
}

impl CloneStrong for Option<AppWindow> {
    fn clone_strong(&self) -> Option<AppWindow> {
        self.as_ref().map(ComponentHandle::clone_strong)
    }
}

fn open_window() {
    with_view(|view| {
        if let Some(window) = &view.window {
            let _ = window.show();
            return;
        }
        let window = match AppWindow::new() {
            Ok(window) => window,
            Err(error) => {
                eprintln!("Couldn't open the window: {error}");
                return;
            }
        };
        window.set_rows(ModelRc::from(view.rows.clone()));
        // Deferred: the size can change while the view is busy showing the window.
        window.on_graphs_resized(|| {
            let _ = slint::invoke_from_event_loop(|| with_view(View::redraw));
        });
        window.on_search_edited(|text| {
            with_view(|view| {
                view.query = text.to_string();
                view.redraw_table();
            });
        });
        window.on_sort_clicked(|index| {
            with_view(|view| {
                let Some(column) = usize::try_from(index).ok().and_then(Column::from_index) else { return };
                let descending = if view.sort.0 == column { !view.sort.1 } else { column.numeric() };
                view.sort = (column, descending);
                view.redraw_table();
            });
        });
        window.on_row_clicked(|index| {
            with_view(|view| {
                view.selected = usize::try_from(index).ok().and_then(|index| view.shown.get(index).copied());
                view.redraw_table();
            });
        });
        window.on_move_selection(|delta| with_view(|view| view.move_selection(delta)));
        // Closing drops the window and its renderer; the tray keeps sampling.
        window.window().on_close_requested(|| {
            let _ = slint::invoke_from_event_loop(|| {
                with_view(|view| {
                    view.window = None;
                    view.processes = None;
                    view.showing.store(false, Ordering::Relaxed);
                })
            });
            CloseRequestResponse::HideWindow
        });
        view.window = Some(window.clone_strong());
        view.showing.store(true, Ordering::Relaxed);
        view.redraw();
        if let Err(error) = window.show() {
            eprintln!("Couldn't show the window: {error}");
        }
    });
}

/// The tray's Open and Quit, run on the UI thread whichever thread the tray uses.
fn on_tray(action: tray::Action) {
    let _ = slint::invoke_from_event_loop(move || match action {
        tray::Action::Open => open_window(),
        tray::Action::Quit => {
            let _ = slint::quit_event_loop();
        }
    });
}

fn main() -> Result<(), slint::PlatformError> {
    // The CPU renderer: a few small redraws a second need no GPU, and it
    // measured lightest by far. SLINT_BACKEND still chooses another.
    if std::env::var_os("SLINT_BACKEND").is_none() {
        slint::BackendSelector::new().backend_name("winit".into()).renderer_name("software".into()).select()?;
    }
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let starts_hidden = arguments.iter().any(|argument| argument == "--hidden");
    let showing = Arc::new(AtomicBool::new(false));
    let history: tray::CpuHistory = Arc::new(Mutex::new(Vec::new()));
    let mut sampler = Sampler::new();
    VIEW.with(|view| {
        *view.borrow_mut() = Some(View {
            window: None,
            snapshots: Ring::new(SPAN),
            disk: AutoScale::new(64.0 * 1024.0, 10),
            network: AutoScale::new(16.0 * 1024.0, 10),
            samples: 0,
            logical_cpus: sampler.logical_cpus().max(1),
            processes: None,
            sort: (Column::Cpu, true),
            query: String::new(),
            rows: Rc::new(VecModel::default()),
            shown: Vec::new(),
            selected: None,
            showing: showing.clone(),
        })
    });

    if !arguments.iter().any(|argument| argument == "--no-tray") {
        tray::start(history.clone(), on_tray);
    }
    if !starts_hidden {
        open_window();
    }

    thread::Builder::new()
        .name("sampler".into())
        .spawn(move || {
            let mut next = Instant::now();
            loop {
                next += INTERVAL;
                let now = Instant::now();
                if next <= now {
                    next = now + INTERVAL;
                }
                thread::sleep(next - now);
                let Some((snapshot, processes)) = sampler.sample(showing.load(Ordering::Relaxed)) else { continue };
                if let Ok(mut values) = history.lock() {
                    values.push(snapshot.cpu);
                    let excess = values.len().saturating_sub(SPAN);
                    values.drain(..excess);
                }
                if slint::invoke_from_event_loop(move || with_view(|view| view.take_sample(snapshot, processes)))
                    .is_err()
                {
                    return;
                }
            }
        })
        .map_err(|error| slint::PlatformError::Other(error.to_string()))?;

    slint::run_event_loop_until_quit()
}
