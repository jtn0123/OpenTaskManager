//! OpenTaskManager drawn natively with Slint: the Tauri app's slice (graphs,
//! process table, tray) on the same Rust core, without a web view. The window
//! exists only while it's open; closing it drops it, and the tray keeps sampling.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod graph;
mod tray;

use std::cell::RefCell;
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
use slint::{CloseRequestResponse, ComponentHandle, ModelRc, SharedString, StandardListViewItem, VecModel};
use tray_icon::menu::MenuEvent;

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
    /// Rows in the order shown, to map a row index back to its process.
    shown: Vec<ProcessKey>,
    selected: Option<ProcessKey>,
    showing: Arc<AtomicBool>,
}

thread_local! {
    static VIEW: RefCell<Option<View>> = const { RefCell::new(None) };
}

/// Runs `change` on the view. A call made while the view is already in use
/// is skipped: those come from Slint answering our own updates (setting the
/// table's selection reports it back), never from the user.
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
        let Some(processes) = &self.processes else {
            window.set_status(format!("Reading processes… · every {} s", INTERVAL.as_secs()).into());
            return;
        };
        let (column, descending) = self.sort;
        let arranged = rows::arrange(processes, &self.query, column, descending, self.logical_cpus);
        self.shown = arranged.iter().map(|row| row.key).collect();
        let model: Vec<ModelRc<StandardListViewItem>> = arranged
            .iter()
            .map(|row| {
                let cells: Vec<StandardListViewItem> = rows::cells(row, self.logical_cpus)
                    .into_iter()
                    .map(|text| StandardListViewItem::from(SharedString::from(text)))
                    .collect();
                ModelRc::new(VecModel::from(cells))
            })
            .collect();
        window.set_rows(ModelRc::new(VecModel::from(model)));
        if let Some(index) = self.selected.and_then(|key| self.shown.iter().position(|shown| *shown == key)) {
            window.invoke_select_row(index as i32);
        } else {
            self.selected = None;
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
        // Deferred: the size can change while the view is busy showing the window.
        window.on_graphs_resized(|| {
            let _ = slint::invoke_from_event_loop(|| with_view(View::redraw));
        });
        window.on_search_edited(|text| {
            with_view(|view| {
                view.query = text.to_string();
                view.redraw();
            });
        });
        let sort = |descending: bool| {
            move |index: i32| {
                with_view(|view| {
                    if let Some(column) = usize::try_from(index).ok().and_then(Column::from_index) {
                        view.sort = (column, descending);
                        view.redraw();
                    }
                });
            }
        };
        window.on_sort_ascending(sort(false));
        window.on_sort_descending(sort(true));
        window.on_row_selected(|index| {
            with_view(|view| {
                view.selected = usize::try_from(index).ok().and_then(|index| view.shown.get(index).copied())
            });
        });
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

fn main() -> Result<(), slint::PlatformError> {
    let starts_hidden = std::env::args().any(|argument| argument == "--hidden");
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
            shown: Vec::new(),
            selected: None,
            showing: showing.clone(),
        })
    });

    MenuEvent::set_event_handler(Some(|event: MenuEvent| {
        let id = event.id.0;
        let _ = slint::invoke_from_event_loop(move || match id.as_str() {
            tray::OPEN => open_window(),
            tray::QUIT => {
                let _ = slint::quit_event_loop();
            }
            _ => {}
        });
    }));
    // `--no-tray` measures the app without the tray's GTK stack on Linux.
    if !std::env::args().any(|argument| argument == "--no-tray") {
        tray::start(history.clone());
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
