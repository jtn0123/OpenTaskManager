//! What the app remembers between runs: window size, the table's sort and
//! view, and how often it samples. A plain `key = value` file in the user's
//! settings folder; anything unreadable falls back to its default, so a bad
//! line never stops the app.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::rows::Column;

/// The update speeds offered, in seconds.
pub const UPDATE_SECONDS: [u64; 3] = [1, 2, 5];

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    /// The window's size in logical pixels, once it has been closed at one.
    pub window: Option<(f32, f32)>,
    pub sort: Column,
    pub descending: bool,
    /// Processes grouped by app (true) or one flat list.
    pub grouped: bool,
    /// One of `UPDATE_SECONDS`.
    pub update_seconds: u64,
    /// Whether the history recorder keeps a record every 10 s.
    pub record_history: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            window: None,
            sort: Column::Cpu,
            descending: true,
            grouped: true,
            update_seconds: 1,
            record_history: true,
        }
    }
}

impl Settings {
    pub fn parse(text: &str) -> Self {
        let mut settings = Self::default();
        let (mut width, mut height) = (None, None);
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else { continue };
            let value = value.trim();
            match key.trim() {
                "window-width" => width = window_length(value),
                "window-height" => height = window_length(value),
                "sort-column" => {
                    if let Some(column) = Column::ALL.into_iter().find(|column| column.key() == value) {
                        settings.sort = column;
                    }
                }
                "sort-order" => match value {
                    "descending" => settings.descending = true,
                    "ascending" => settings.descending = false,
                    _ => {}
                },
                "view" => match value {
                    "grouped" => settings.grouped = true,
                    "flat" => settings.grouped = false,
                    _ => {}
                },
                "record-history" => match value {
                    "on" => settings.record_history = true,
                    "off" => settings.record_history = false,
                    _ => {}
                },
                "update-seconds" => {
                    if let Some(seconds) = value.parse().ok().filter(|seconds| UPDATE_SECONDS.contains(seconds)) {
                        settings.update_seconds = seconds;
                    }
                }
                _ => {}
            }
        }
        settings.window = width.zip(height);
        settings
    }

    pub fn to_text(&self) -> String {
        let mut text = String::from("# OpenTaskManager's settings, rewritten when they change.\n");
        if let Some((width, height)) = self.window {
            text += &format!("window-width = {}\nwindow-height = {}\n", width.round(), height.round());
        }
        text += &format!(
            "sort-column = {}\nsort-order = {}\nview = {}\nupdate-seconds = {}\nrecord-history = {}\n",
            self.sort.key(),
            if self.descending { "descending" } else { "ascending" },
            if self.grouped { "grouped" } else { "flat" },
            self.update_seconds,
            if self.record_history { "on" } else { "off" }
        );
        text
    }

    /// Reads `path`; a missing or unreadable file gives the defaults.
    pub fn load(path: &Path) -> Self {
        fs::read_to_string(path).map(|text| Self::parse(&text)).unwrap_or_default()
    }

    /// Writes `path` whole or not at all, through a file beside it.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(folder) = path.parent() {
            fs::create_dir_all(folder)?;
        }
        let staged = path.with_extension("conf.new");
        fs::write(&staged, self.to_text())?;
        fs::rename(&staged, path)
    }
}

/// Sizes outside what any screen would use are ignored.
fn window_length(value: &str) -> Option<f32> {
    value.parse::<f32>().ok().filter(|length| (200.0..=20_000.0).contains(length))
}

/// The settings file for `instance` ("default" is the usual one; tests run
/// their own), in the user's settings folder.
pub fn path(instance: &str) -> Option<PathBuf> {
    let file = if instance == crate::instance::DEFAULT {
        "settings.conf".to_owned()
    } else {
        format!("settings-{instance}.conf")
    };
    folder().map(|folder| folder.join(file))
}

#[cfg(windows)]
fn folder() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("OpenTaskManager"))
}

#[cfg(target_os = "macos")]
fn folder() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Library/Application Support/OpenTaskManager"))
}

#[cfg(not(any(windows, target_os = "macos")))]
fn folder() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(config.join("opentaskmanager"))
}

#[cfg(test)]
mod tests {
    use super::{Settings, path};
    use crate::rows::Column;

    #[test]
    fn round_trips_every_setting() {
        let settings = Settings {
            window: Some((1280.0, 800.0)),
            sort: Column::DiskWrite,
            descending: false,
            grouped: false,
            update_seconds: 5,
            record_history: false,
        };
        assert_eq!(Settings::parse(&settings.to_text()), settings);
        assert_eq!(Settings::parse(&Settings::default().to_text()), Settings::default());
    }

    #[test]
    fn unreadable_lines_keep_their_defaults() {
        let text = "window-width = 9000000\nwindow-height = 700\nsort-column = colour\nsort-order = sideways\n\
                    update-seconds = 3\nview = tree\nnonsense\n# a comment = here\n";
        assert_eq!(Settings::parse(text), Settings::default());
        let half = Settings::parse("window-width = 1000\n");
        assert_eq!(half.window, None, "a width alone isn't a size");
    }

    #[test]
    fn saves_whole_and_loads_back() {
        let folder = std::env::temp_dir().join(format!("otm-settings-test-{}", std::process::id()));
        let file = folder.join("settings.conf");
        assert_eq!(Settings::load(&file), Settings::default(), "no file yet");
        let settings = Settings { sort: Column::Memory, update_seconds: 2, ..Settings::default() };
        settings.save(&file).expect("saved");
        assert_eq!(Settings::load(&file), settings);
        assert!(!file.with_extension("conf.new").exists(), "nothing left beside it");
        std::fs::remove_dir_all(&folder).expect("cleanup");
    }

    #[test]
    fn each_instance_has_its_own_file() {
        let default = path("default").expect("a settings folder");
        let other = path("smoke-1").expect("a settings folder");
        assert!(default.ends_with("settings.conf"));
        assert!(other.ends_with("settings-smoke-1.conf"));
        assert_eq!(default.parent(), other.parent());
    }
}
