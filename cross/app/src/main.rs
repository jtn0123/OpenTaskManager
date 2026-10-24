//! OpenTaskManager for Windows and Linux, drawn natively with Slint on the
//! shared Rust core. The window exists only while it's open; closing it
//! drops it, and the tray keeps sampling.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod graph;
mod table;
mod tray;

use std::cell::RefCell;
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use otm_core::autostart;
use otm_core::details::Details;
use otm_core::format::{MISSING, axis_rate, bytes, percent, rate};
use otm_core::groups::Grouping;
use otm_core::history::Ring;
use otm_core::instance::{self, Claim, Message};
use otm_core::model::{ProcessKey, ProcessRow, Snapshot};
use otm_core::rows::Column;
use otm_core::sampler::Sampler;
use otm_core::scale::AutoScale;
use otm_core::settings::{self, Settings, UPDATE_SECONDS};
use slint::{CloseRequestResponse, ComponentHandle, ModelRc, VecModel};
use table::{Pick, Targets};

slint::include_modules!();

/// Samples the graphs span: a minute at one a second, five at one every five.
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
    /// What each row stands for, in the order shown.
    shown: Vec<Pick>,
    selected: Option<Pick>,
    /// Processes grouped by app (true) or one flat list.
    grouped: bool,
    /// Each process's group, worked out once per sample.
    grouping: Option<Grouping>,
    /// Groups opened to show their members, by their top process.
    expanded: HashSet<ProcessKey>,
    /// The selected process's program and command line, read once per selection.
    details: Option<(ProcessKey, Option<Details>)>,
    /// The details panel's lines, changed in place.
    facts: Rc<VecModel<Fact>>,
    /// Force Quit's targets while its question is open, fixed as it opened.
    pending: Option<Targets>,
    /// What the last End Task or Force Quit did, until dismissed.
    notice: String,
    showing: Arc<AtomicBool>,
    /// The instance this copy answers to, which names its settings and sign-in entry.
    instance: String,
    settings_path: Option<PathBuf>,
    /// The window's last size in logical pixels, kept while it's closed.
    window_size: Option<(f32, f32)>,
    /// Seconds between samples, read by the sampler thread.
    update_seconds: Arc<AtomicU64>,
    sampler: Option<thread::Thread>,
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

    fn save_settings(&self) {
        let Some(path) = &self.settings_path else { return };
        let settings = Settings {
            window: self.window_size,
            sort: self.sort.0,
            descending: self.sort.1,
            grouped: self.grouped,
            update_seconds: self.update_seconds.load(Ordering::Relaxed),
        };
        if let Err(error) = settings.save(path) {
            eprintln!("Couldn't save settings to {}: {error}", path.display());
        }
    }

    /// Keeps the open window's size for next time, unless it fills the screen.
    fn remember_window_size(&mut self) {
        let Some(window) = &self.window else { return };
        let window = window.window();
        if window.is_maximized() || window.is_minimized() || window.is_fullscreen() {
            return;
        }
        let size = window.size().to_logical(window.scale_factor());
        if size.width > 0.0 && size.height > 0.0 {
            self.window_size = Some((size.width, size.height));
        }
    }

    fn choose_update_speed(&mut self, index: i32) {
        let Some(seconds) = usize::try_from(index).ok().and_then(|index| UPDATE_SECONDS.get(index)) else { return };
        if self.update_seconds.swap(*seconds, Ordering::Relaxed) != *seconds {
            // Wake the sampler so the new speed starts now, not after the old interval.
            if let Some(sampler) = &self.sampler {
                sampler.unpark();
            }
            self.save_settings();
        }
    }

    fn set_starts_at_sign_in(&mut self, on: bool) {
        if let Err(error) = autostart::set(&self.instance, on) {
            self.notice = format!("Couldn't change starting at sign-in: {error}.");
        }
        if let Some(window) = self.window.clone_strong() {
            window.set_starts_at_sign_in(starts_at_sign_in(&self.instance));
            self.draw_actions(&window);
        }
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
        if let Some(processes) = processes {
            self.grouping = Some(Grouping::new(&processes));
            self.processes = Some(processes);
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
            bring_to_front(window);
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
        window.set_details(ModelRc::from(view.facts.clone()));
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
                view.save_settings();
            });
        });
        window.on_row_clicked(|index| with_view(|view| view.click_row(index)));
        window.on_toggle_group(|index| with_view(|view| view.toggle_group(index)));
        window.on_expand_group(|index| with_view(|view| view.expand_group(index)));
        window.on_expand_selection(|open| with_view(|view| view.expand_selection(open)));
        window.on_grouped_toggled(|grouped| with_view(|view| view.set_grouped(grouped)));
        window.on_move_selection(|delta| with_view(|view| view.move_selection(delta)));
        window.on_end_task(|| with_view(View::end_task));
        window.on_force_quit_asked(|| with_view(View::ask_force_quit));
        window.on_force_quit_confirmed(|| with_view(View::force_quit));
        window.on_escape_pressed(|| with_view(View::escape));
        window.on_update_chosen(|index| with_view(|view| view.choose_update_speed(index)));
        window.on_sign_in_toggled(|on| with_view(|view| view.set_starts_at_sign_in(on)));
        let seconds = view.update_seconds.load(Ordering::Relaxed);
        window.set_update_index(UPDATE_SECONDS.iter().position(|each| *each == seconds).unwrap_or(0) as i32);
        window.set_starts_at_sign_in(starts_at_sign_in(&view.instance));
        if let Some((width, height)) = view.window_size {
            window.window().set_size(slint::LogicalSize::new(width, height));
        }
        // Closing drops the window and its renderer; the tray keeps sampling.
        window.window().on_close_requested(|| {
            let _ = slint::invoke_from_event_loop(|| {
                with_view(|view| {
                    view.remember_window_size();
                    view.save_settings();
                    view.window = None;
                    view.processes = None;
                    view.grouping = None;
                    view.details = None;
                    view.pending = None;
                    view.notice.clear();
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
        bring_to_front(&window);
    });
}

fn starts_at_sign_in(instance: &str) -> bool {
    autostart::user_place().is_ok_and(|place| autostart::is_enabled(&place, instance))
}

/// Shows the window over others when another launch asked for it: that
/// launch, being the user's, lets this copy take the foreground.
fn bring_to_front(window: &AppWindow) {
    window.window().set_minimized(false);
    #[cfg(windows)]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        use windows_sys::Win32::UI::WindowsAndMessaging::SetForegroundWindow;
        let handle = window.window().window_handle();
        if let Ok(handle) = handle.window_handle()
            && let RawWindowHandle::Win32(win32) = handle.as_raw()
        {
            // SAFETY: the handle is this window's own, alive while `window` is.
            unsafe { SetForegroundWindow(win32.hwnd.get() as _) };
        }
    }
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

/// A request from another launch of this instance.
fn on_launch(message: Message) {
    let _ = slint::invoke_from_event_loop(move || match message {
        Message::Open => open_window(),
        Message::Quit => {
            let _ = slint::quit_event_loop();
        }
    });
}

/// The value after `flag`, as in `--exit-after 30`.
fn option<'a>(arguments: &'a [String], flag: &str) -> Option<&'a str> {
    let at = arguments.iter().position(|argument| argument == flag)?;
    arguments.get(at + 1).map(String::as_str)
}

fn main() -> Result<(), slint::PlatformError> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| arguments.iter().any(|argument| argument == name);
    // `--instance NAME` runs a copy with its own settings and sign-in entry
    // (for tests); `--quit` asks the running copy to quit.
    let instance = option(&arguments, "--instance").unwrap_or(instance::DEFAULT).to_owned();
    if !instance::valid_name(&instance) {
        eprintln!("An instance name is letters, digits, '-' and '_', at most 64.");
        std::process::exit(2);
    }
    let starts_hidden = flag("--hidden");
    let listener = match instance::claim(&instance) {
        Ok(Claim::First(_)) if flag("--quit") => {
            println!("OpenTaskManager isn't running.");
            return Ok(());
        }
        Ok(Claim::First(listener)) => Some(listener),
        Ok(Claim::Running) => {
            // A sign-in launch finding a copy already running has nothing to do.
            let message = if flag("--quit") { Message::Quit } else { Message::Open };
            if (message == Message::Quit || !starts_hidden)
                && let Err(error) = instance::send(&instance, message)
            {
                eprintln!("OpenTaskManager is running but didn't answer: {error}");
                std::process::exit(1);
            }
            return Ok(());
        }
        Err(error) => {
            eprintln!("Couldn't check for another copy, so starting anyway: {error}");
            None
        }
    };

    // The CPU renderer: a few small redraws a second need no GPU, and it
    // measured lightest by far. SLINT_BACKEND still chooses another.
    if std::env::var_os("SLINT_BACKEND").is_none() {
        slint::BackendSelector::new().backend_name("winit".into()).renderer_name("software".into()).select()?;
    }
    // `--exit-after SECONDS` quits cleanly after a while, for measurements and tests.
    let exit_after = option(&arguments, "--exit-after").and_then(|seconds| seconds.parse::<u64>().ok());
    let settings_path = settings::path(&instance);
    let saved = settings_path.as_deref().map(Settings::load).unwrap_or_default();
    let update_seconds = Arc::new(AtomicU64::new(saved.update_seconds));
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
            sort: (saved.sort, saved.descending),
            query: String::new(),
            rows: Rc::new(VecModel::default()),
            shown: Vec::new(),
            selected: None,
            grouped: saved.grouped,
            grouping: None,
            expanded: HashSet::new(),
            details: None,
            facts: Rc::new(VecModel::default()),
            pending: None,
            notice: String::new(),
            showing: showing.clone(),
            instance: instance.clone(),
            settings_path,
            window_size: saved.window,
            update_seconds: update_seconds.clone(),
            sampler: None,
        })
    });

    if !flag("--no-tray") {
        tray::start(history.clone(), on_tray);
    }
    if let Some(listener) = listener {
        listener.serve(on_launch);
    }
    if !starts_hidden {
        open_window();
    }

    let sampler_thread = thread::Builder::new()
        .name("sampler".into())
        .spawn(move || {
            let mut next = Instant::now();
            loop {
                let seconds = update_seconds.load(Ordering::Relaxed);
                let interval = Duration::from_secs(seconds);
                next += interval;
                if next <= Instant::now() {
                    next = Instant::now() + interval;
                }
                // Parked rather than asleep, so a new update speed takes effect at once.
                while let Some(left) = next.checked_duration_since(Instant::now()).filter(|left| !left.is_zero()) {
                    thread::park_timeout(left);
                    if update_seconds.load(Ordering::Relaxed) != seconds {
                        next = Instant::now();
                        break;
                    }
                }
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
    with_view(|view| view.sampler = Some(sampler_thread.thread().clone()));

    let exit_timer = slint::Timer::default();
    if let Some(seconds) = exit_after {
        exit_timer.start(slint::TimerMode::SingleShot, Duration::from_secs(seconds), || {
            let _ = slint::quit_event_loop();
        });
    }
    let result = slint::run_event_loop_until_quit();
    with_view(|view| {
        view.remember_window_size();
        view.save_settings();
    });
    tray::stop();
    result
}
