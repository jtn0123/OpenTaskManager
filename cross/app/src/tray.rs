//! The tray icon, drawing recent CPU load (`otm_core::icon`). On Linux it's a
//! StatusNotifierItem over D-Bus (`ksni`), so no GTK is loaded; elsewhere it's
//! the system's own tray through `tray-icon`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use otm_core::icon::cpu_bars;

const SIZE: u32 = 32;
const REDRAW: Duration = Duration::from_secs(1);
const OPEN_LABEL: &str = "Open OpenTaskManager";
const QUIT_LABEL: &str = "Quit OpenTaskManager";

/// Recent CPU readings, written by the sampler and drawn by the tray.
pub type CpuHistory = Arc<Mutex<Vec<f32>>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Open,
    Quit,
}

fn values(history: &CpuHistory) -> Vec<f32> {
    history.lock().map(|values| values.clone()).unwrap_or_default()
}

#[cfg(target_os = "linux")]
mod platform {
    use std::thread;

    use ksni::blocking::TrayMethods;
    use ksni::menu::StandardItem;
    use otm_core::icon::to_argb;

    use super::{Action, CpuHistory, OPEN_LABEL, QUIT_LABEL, REDRAW, SIZE, cpu_bars, values};

    struct CpuTray {
        values: Vec<f32>,
        act: fn(Action),
    }

    impl ksni::Tray for CpuTray {
        fn id(&self) -> String {
            "opentaskmanager".into()
        }

        fn title(&self) -> String {
            "OpenTaskManager".into()
        }

        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            let side = SIZE as i32;
            vec![ksni::Icon { width: side, height: side, data: to_argb(&cpu_bars(&self.values, SIZE)) }]
        }

        fn activate(&mut self, _x: i32, _y: i32) {
            (self.act)(Action::Open);
        }

        fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
            let item = |label: &str, action: Action| -> ksni::MenuItem<Self> {
                StandardItem {
                    label: label.into(),
                    activate: Box::new(move |tray: &mut Self| (tray.act)(action)),
                    ..Default::default()
                }
                .into()
            };
            vec![item(OPEN_LABEL, Action::Open), item(QUIT_LABEL, Action::Quit)]
        }
    }

    pub fn start(history: CpuHistory, act: fn(Action)) {
        let handle = match (CpuTray { values: Vec::new(), act }).spawn() {
            Ok(handle) => handle,
            Err(error) => {
                eprintln!("No tray icon: {error}");
                return;
            }
        };
        let redraw = thread::Builder::new().name("tray".into()).spawn(move || {
            loop {
                thread::sleep(REDRAW);
                let latest = values(&history);
                if handle.update(|tray| tray.values = latest).is_none() {
                    return;
                }
            }
        });
        if let Err(error) = redraw {
            eprintln!("The tray icon won't update: {error}");
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod platform {
    use tray_icon::menu::{Menu, MenuEvent, MenuItem};
    use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

    use super::{Action, CpuHistory, OPEN_LABEL, QUIT_LABEL, REDRAW, SIZE, cpu_bars, values};

    const OPEN: &str = "open";
    const QUIT: &str = "quit";

    fn icon(history: &CpuHistory) -> Option<Icon> {
        Icon::from_rgba(cpu_bars(&values(history), SIZE), SIZE, SIZE).ok()
    }

    /// The tray lives on the main thread, redrawn by a Slint timer.
    pub fn start(history: CpuHistory, act: fn(Action)) {
        thread_local! {
            static REDRAW_TIMER: std::cell::RefCell<Option<slint::Timer>> = const { std::cell::RefCell::new(None) };
        }
        let menu = Menu::new();
        let open = MenuItem::with_id(OPEN, OPEN_LABEL, true, None);
        let quit = MenuItem::with_id(QUIT, QUIT_LABEL, true, None);
        if menu.append_items(&[&open, &quit]).is_err() {
            return;
        }
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| match event.id.0.as_str() {
            OPEN => act(Action::Open),
            QUIT => act(Action::Quit),
            _ => {}
        }));
        TrayIconEvent::set_event_handler(Some(move |event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                act(Action::Open);
            }
        }));
        let mut builder = TrayIconBuilder::new().with_menu(Box::new(menu)).with_tooltip("OpenTaskManager");
        if let Some(icon) = icon(&history) {
            builder = builder.with_icon(icon);
        }
        let tray = match builder.build() {
            Ok(tray) => tray,
            Err(error) => {
                eprintln!("No tray icon: {error}");
                return;
            }
        };
        let timer = slint::Timer::default();
        // The timer owns the tray, so it lives as long as the app does.
        timer.start(slint::TimerMode::Repeated, REDRAW, move || {
            let _ = tray.set_icon(icon(&history));
        });
        REDRAW_TIMER.with(|slot| *slot.borrow_mut() = Some(timer));
    }
}

/// Starts the tray. `act` runs, on whichever thread the tray uses, when the
/// user picks Open or Quit or clicks the icon.
pub fn start(history: CpuHistory, act: fn(Action)) {
    platform::start(history, act);
}
