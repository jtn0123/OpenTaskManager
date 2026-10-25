//! Sampling and the figures behind OpenTaskManager's cross-platform app.
//!
//! The rule carried over from the Mac app: a figure the system didn't give
//! is `None`, shown as "—", never zero. Pure rules live here, tested; the
//! app only schedules sampling and draws.

pub mod actions;
pub mod autostart;
pub mod details;
pub mod format;
pub mod gpu;
pub mod groups;
pub mod history;
pub mod icon;
pub mod instance;
pub mod model;
#[cfg(windows)]
pub mod registry;
pub mod rows;
pub mod sampler;
pub mod scale;
pub mod settings;
pub mod startup;
