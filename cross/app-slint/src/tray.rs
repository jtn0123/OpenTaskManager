//! The tray icon, drawing recent CPU load (`otm_core::icon`). Its menu events
//! arrive through `tray_icon`'s global handler, set in `main`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use otm_core::icon::cpu_bars;
use tray_icon::menu::{Menu, MenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

pub const OPEN: &str = "open";
pub const QUIT: &str = "quit";
const SIZE: u32 = 32;
const REDRAW: Duration = Duration::from_secs(1);

/// Recent CPU readings, written by the sampler and drawn by the tray.
pub type CpuHistory = Arc<Mutex<Vec<f32>>>;

fn icon(history: &CpuHistory) -> Option<Icon> {
    let values = history.lock().map(|values| values.clone()).unwrap_or_default();
    Icon::from_rgba(cpu_bars(&values, SIZE), SIZE, SIZE).ok()
}

fn build(history: &CpuHistory) -> Option<TrayIcon> {
    let menu = Menu::new();
    let open = MenuItem::with_id(OPEN, "Open OpenTaskManager", true, None);
    let quit = MenuItem::with_id(QUIT, "Quit OpenTaskManager", true, None);
    menu.append_items(&[&open, &quit]).ok()?;
    let mut builder = TrayIconBuilder::new().with_menu(Box::new(menu));
    if let Some(icon) = icon(history) {
        builder = builder.with_icon(icon);
    }
    match builder.build() {
        Ok(tray) => Some(tray),
        Err(error) => {
            eprintln!("No tray icon: {error}");
            None
        }
    }
}

/// Linux's tray library needs a GTK main loop; Slint's runs on the main
/// thread, so GTK gets a thread of its own.
#[cfg(target_os = "linux")]
pub fn start(history: CpuHistory) {
    use gtk::glib;
    let spawned = std::thread::Builder::new().name("tray".into()).spawn(move || {
        if let Err(error) = gtk::init() {
            eprintln!("No tray icon: GTK couldn't start ({error})");
            return;
        }
        let Some(tray) = build(&history) else { return };
        glib::timeout_add_local(REDRAW, move || {
            let _ = tray.set_icon(icon(&history));
            glib::ControlFlow::Continue
        });
        gtk::main();
    });
    if let Err(error) = spawned {
        eprintln!("No tray icon: {error}");
    }
}

/// Elsewhere the tray lives on the main thread, redrawn by a Slint timer.
#[cfg(not(target_os = "linux"))]
pub fn start(history: CpuHistory) {
    thread_local! {
        static REDRAW_TIMER: std::cell::RefCell<Option<slint::Timer>> = const { std::cell::RefCell::new(None) };
    }
    let Some(tray) = build(&history) else { return };
    let timer = slint::Timer::default();
    // The timer owns the tray, so it lives as long as the app does.
    timer.start(slint::TimerMode::Repeated, REDRAW, move || {
        let _ = tray.set_icon(icon(&history));
    });
    REDRAW_TIMER.with(|slot| *slot.borrow_mut() = Some(timer));
}
