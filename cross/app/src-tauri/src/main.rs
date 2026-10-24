//! OpenTaskManager for Windows and Linux. A tray icon samples the machine
//! cheaply all the time; the window, which exists only while it's open,
//! adds processes and live graphs. Closing it destroys its webview, so the
//! app then costs one small process.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use otm_core::history::Ring;
use otm_core::icon::cpu_bars;
use otm_core::model::{HistoryReply, Scales, Snapshot, Tick};
use otm_core::sampler::Sampler;
use otm_core::scale::AutoScale;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

const MAIN_WINDOW: &str = "main";
const TRAY: &str = "cpu";
const INTERVAL: Duration = Duration::from_secs(1);
/// Samples the graphs span: a minute at one a second.
const SPAN: usize = 60;
const TRAY_ICON_SIZE: u32 = 32;

/// The graphs' recent past, kept while the window is closed so it opens
/// with history instead of an empty graph.
struct Recorded {
    snapshots: Ring<Snapshot>,
    disk: AutoScale,
    network: AutoScale,
    logical_cpus: usize,
    slide_graphs: Option<bool>,
}

type Shared = Arc<Mutex<Recorded>>;

impl Recorded {
    fn scales(&self) -> Scales {
        Scales { disk: self.disk.bound(), network: self.network.bound() }
    }

    /// Records `snapshot` and refits the rate axes to what's now visible.
    fn push(&mut self, snapshot: Snapshot) -> Scales {
        self.snapshots.push(snapshot);
        let (mut disk, mut network) = (0f64, 0f64);
        for snapshot in self.snapshots.iter() {
            if let Some(rates) = snapshot.disk {
                disk = disk.max(rates.read).max(rates.write);
            }
            if let Some(rates) = snapshot.network {
                network = network.max(rates.received).max(rates.sent);
            }
        }
        self.disk.update(disk);
        self.network.update(network);
        self.scales()
    }
}

fn lock(shared: &Shared) -> MutexGuard<'_, Recorded> {
    // A panic elsewhere can't leave the ring half-written, so a poisoned lock is still usable.
    shared.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[tauri::command]
fn history(recorded: tauri::State<'_, Shared>) -> HistoryReply {
    let recorded = lock(&recorded);
    HistoryReply {
        snapshots: recorded.snapshots.to_vec(),
        scales: recorded.scales(),
        logical_cpus: recorded.logical_cpus as u32,
        capacity: SPAN as u32,
        interval: INTERVAL.as_secs_f64(),
        slide_graphs: recorded.slide_graphs,
    }
}

fn tray_icon(values: &[f32]) -> Image<'static> {
    Image::new_owned(cpu_bars(values, TRAY_ICON_SIZE), TRAY_ICON_SIZE, TRAY_ICON_SIZE)
}

fn show_main_window(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW) {
        window.unminimize()?;
        window.show()?;
        return window.set_focus();
    }
    WebviewWindowBuilder::new(app, MAIN_WINDOW, WebviewUrl::default())
        .title("OpenTaskManager")
        .inner_size(1120.0, 760.0)
        .min_inner_size(760.0, 520.0)
        .build()?;
    Ok(())
}

fn install_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open OpenTaskManager", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit OpenTaskManager", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &quit])?;
    TrayIconBuilder::with_id(TRAY)
        .icon(tray_icon(&[]))
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => {
                if let Err(error) = show_main_window(app) {
                    eprintln!("Couldn't open the window: {error}");
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event
                && let Err(error) = show_main_window(tray.app_handle())
            {
                eprintln!("Couldn't open the window: {error}");
            }
        })
        .build(app)?;
    Ok(())
}

/// Samples once per interval for as long as the app runs. Processes are read
/// only while the window is on screen; totals go to the window whenever it exists.
fn sample_forever(app: AppHandle, recorded: Shared, mut sampler: Sampler) {
    let mut next = Instant::now();
    loop {
        next += INTERVAL;
        let now = Instant::now();
        if next <= now {
            // Asleep or stalled: start afresh rather than catching up in a burst.
            next = now + INTERVAL;
        }
        thread::sleep(next - now);

        let window = app.get_webview_window(MAIN_WINDOW);
        let showing = window
            .as_ref()
            .is_some_and(|window| window.is_visible().unwrap_or(false) && !window.is_minimized().unwrap_or(true));
        let Some((snapshot, processes)) = sampler.sample(showing) else { continue };
        let (scales, cpu) = {
            let mut recorded = lock(&recorded);
            let scales = recorded.push(snapshot.clone());
            (scales, recorded.snapshots.iter().map(|snapshot| snapshot.cpu).collect::<Vec<_>>())
        };
        if let Some(tray) = app.tray_by_id(TRAY) {
            let _ = tray.set_icon(Some(tray_icon(&cpu)));
            // Linux tray indicators have no tooltip; setting one there only logs GTK warnings.
            #[cfg(not(target_os = "linux"))]
            let _ = tray.set_tooltip(Some(format!("OpenTaskManager · CPU {:.0}%", snapshot.cpu)));
        }
        // A minimized window still gets the totals, so its graphs have no hole when it returns;
        // the page doesn't draw while hidden, and processes aren't read.
        if window.is_some()
            && let Err(error) = app.emit_to(MAIN_WINDOW, "tick", Tick { snapshot, processes, scales })
        {
            eprintln!("Couldn't send a sample to the window: {error}");
        }
    }
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let starts_hidden = arguments.iter().any(|argument| argument == "--hidden");
    // The last of --slide-graphs and --step-graphs wins; neither lets the interface decide.
    let slide_graphs = arguments.iter().rev().find_map(|argument| match argument.as_str() {
        "--slide-graphs" => Some(true),
        "--step-graphs" => Some(false),
        _ => None,
    });
    let sampler = Sampler::new();
    let recorded: Shared = Arc::new(Mutex::new(Recorded {
        snapshots: Ring::new(SPAN),
        disk: AutoScale::new(64.0 * 1024.0, 10),
        network: AutoScale::new(16.0 * 1024.0, 10),
        logical_cpus: sampler.logical_cpus(),
        slide_graphs,
    }));
    let for_sampler = recorded.clone();
    tauri::Builder::default()
        .manage(recorded)
        .invoke_handler(tauri::generate_handler![history])
        .setup(move |app| {
            install_tray(app.handle())?;
            if !starts_hidden {
                show_main_window(app.handle())?;
            }
            let handle = app.handle().clone();
            thread::Builder::new()
                .name("sampler".into())
                .spawn(move || sample_forever(handle, for_sampler, sampler))?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("OpenTaskManager couldn't start")
        .run(|_app, event| {
            // The last window closing isn't quitting: the tray stays. Quit comes from its menu.
            if let RunEvent::ExitRequested { code: None, api, .. } = event {
                api.prevent_exit();
            }
        });
}
