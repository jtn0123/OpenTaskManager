//! What starts at sign-in, as the system's own lists give it: on Windows
//! the Run keys and Startup folders, each item on or off as Task Manager's
//! Startup page last left it; on Linux the XDG autostart folders, an
//! account's entry replacing the system's of the same name. Read when the
//! Startup page opens or is refreshed, never per tick.
//!
//! Turning an item on or off writes what the system's own tools write, so
//! they agree: Explorer's approval mark on Windows (never the Run value or
//! the file itself), and on Linux `Hidden` and GNOME's switch in the
//! account's copy of the entry.

use std::io;
use std::path::Path;

pub use platform::Switch;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartupItem {
    pub name: String,
    /// The command it runs, or the file it opens.
    pub command: String,
    /// Where it's listed, in words.
    pub source: String,
    /// Whether it will start at the next sign-in.
    pub enabled: bool,
    /// Where its on/off state is kept.
    pub switch: Switch,
}

/// Every item, by name.
pub fn read() -> Vec<StartupItem> {
    let mut items = platform::read();
    items.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then(a.source.cmp(&b.source)));
    items
}

/// Turns `item` on or off for the next sign-in. Items listed for every
/// account need administrator rights to change on Windows.
pub fn set_enabled(item: &StartupItem, on: bool) -> io::Result<()> {
    platform::set_enabled(&item.switch, on)
}

/// Whether `item` matches a search: its name or command containing it.
pub fn matches(item: &StartupItem, query: &str) -> bool {
    let query = query.trim().to_lowercase();
    query.is_empty() || item.name.to_lowercase().contains(&query) || item.command.to_lowercase().contains(&query)
}

/// A file's name without its extension, for items named by their file.
fn stem(path: &Path) -> String {
    path.file_stem().map_or_else(|| path.display().to_string(), |stem| stem.to_string_lossy().into_owned())
}

#[cfg(windows)]
mod platform {
    use std::fs;
    use std::io;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{StartupItem, stem};
    use crate::autostart::turned_off;
    use crate::registry::{self, Hive};

    /// Explorer's approval mark for one item: its key and value name.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Switch {
        hive: Hive,
        key: String,
        value: String,
    }

    /// Task Manager's marks: 2 on; 3 off, followed by when it was turned off.
    pub(super) fn mark(on: bool, now: SystemTime) -> Vec<u8> {
        let mut mark = vec![if on { 2 } else { 3 }, 0, 0, 0];
        let since_1601 = now.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_nanos() / 100) as u64
            + 11_644_473_600 * 10_000_000;
        mark.extend(if on { 0 } else { since_1601 }.to_le_bytes());
        mark
    }

    #[cfg(test)]
    impl Switch {
        pub(crate) fn placeholder() -> Self {
            Self { hive: Hive::User, key: String::new(), value: String::new() }
        }
    }

    pub fn set_enabled(switch: &Switch, on: bool) -> io::Result<()> {
        registry::write_binary(switch.hive, &switch.key, &switch.value, &mark(on, SystemTime::now()))
    }

    const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const APPROVED: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved";

    pub(super) enum Place {
        Key { hive: Hive, key: String },
        Folder(PathBuf),
    }

    /// One list of items, and where Explorer records which of them are turned off.
    pub(super) struct Source {
        pub title: &'static str,
        pub place: Place,
        pub approved: (Hive, String),
    }

    fn sources() -> Vec<Source> {
        let mut sources = vec![
            Source {
                title: "Your Run key",
                place: Place::Key { hive: Hive::User, key: RUN.to_owned() },
                approved: (Hive::User, format!(r"{APPROVED}\Run")),
            },
            Source {
                title: "All accounts' Run key",
                place: Place::Key { hive: Hive::Machine, key: RUN.to_owned() },
                approved: (Hive::Machine, format!(r"{APPROVED}\Run")),
            },
            Source {
                title: "All accounts' Run key (32-bit)",
                place: Place::Key { hive: Hive::Machine32, key: RUN.to_owned() },
                approved: (Hive::Machine, format!(r"{APPROVED}\Run32")),
            },
        ];
        let folder = r"Microsoft\Windows\Start Menu\Programs\Startup";
        if let Some(appdata) = std::env::var_os("APPDATA") {
            sources.push(Source {
                title: "Your Startup folder",
                place: Place::Folder(PathBuf::from(appdata).join(folder)),
                approved: (Hive::User, format!(r"{APPROVED}\StartupFolder")),
            });
        }
        if let Some(programdata) = std::env::var_os("ProgramData") {
            sources.push(Source {
                title: "All accounts' Startup folder",
                place: Place::Folder(PathBuf::from(programdata).join(folder)),
                approved: (Hive::Machine, format!(r"{APPROVED}\StartupFolder")),
            });
        }
        sources
    }

    pub(super) fn read_sources(sources: &[Source]) -> Vec<StartupItem> {
        let mut items = Vec::new();
        for source in sources {
            let (hive, key) = &source.approved;
            let enabled = |name: &str| !registry::read_binary(*hive, key, name).is_some_and(|state| turned_off(&state));
            let switch = |name: &str| Switch { hive: *hive, key: key.clone(), value: name.to_owned() };
            match &source.place {
                Place::Key { hive, key } => {
                    for (name, command) in registry::strings(*hive, key) {
                        items.push(StartupItem {
                            enabled: enabled(&name),
                            switch: switch(&name),
                            name,
                            command,
                            source: source.title.to_owned(),
                        });
                    }
                }
                Place::Folder(folder) => {
                    let Ok(entries) = fs::read_dir(folder) else { continue };
                    for entry in entries.flatten() {
                        let file = entry.file_name().to_string_lossy().into_owned();
                        if file.eq_ignore_ascii_case("desktop.ini") || !entry.path().is_file() {
                            continue;
                        }
                        items.push(StartupItem {
                            enabled: enabled(&file),
                            switch: switch(&file),
                            name: stem(&entry.path()),
                            command: entry.path().display().to_string(),
                            source: source.title.to_owned(),
                        });
                    }
                }
            }
        }
        items
    }

    pub fn read() -> Vec<StartupItem> {
        read_sources(&sources())
    }
}

#[cfg(not(windows))]
mod platform {
    use std::collections::HashSet;
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};

    use super::{StartupItem, stem};
    use crate::autostart::desktop_entry_enabled;

    /// The entry file it was read from, and the account's folder, where a
    /// changed copy of a system entry goes.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Switch {
        file: PathBuf,
        account_folder: PathBuf,
    }

    /// The entry with its on/off keys set: off is `Hidden=true` (the spec's)
    /// with GNOME's `X-GNOME-Autostart-enabled=false`; on is neither.
    pub(super) fn switched(text: &str, on: bool) -> String {
        let mut out = String::with_capacity(text.len() + 48);
        let mut in_entry = false;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('[') {
                in_entry = trimmed == "[Desktop Entry]";
                out.push_str(line);
                out.push('\n');
                if in_entry && !on {
                    out.push_str("Hidden=true\nX-GNOME-Autostart-enabled=false\n");
                }
                continue;
            }
            let key = trimmed.split_once('=').map(|(key, _)| key.trim());
            if in_entry && matches!(key, Some("Hidden" | "X-GNOME-Autostart-enabled")) {
                continue;
            }
            out.push_str(line);
            out.push('\n');
        }
        out
    }

    #[cfg(test)]
    impl Switch {
        pub(crate) fn placeholder() -> Self {
            Self { file: PathBuf::new(), account_folder: PathBuf::new() }
        }
    }

    /// Changes the account's own entry; a system entry gets an account copy
    /// that replaces it, as the spec has it.
    pub fn set_enabled(switch: &Switch, on: bool) -> io::Result<()> {
        let text = fs::read_to_string(&switch.file)?;
        let name = switch.file.file_name().ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        fs::create_dir_all(&switch.account_folder)?;
        let target = switch.account_folder.join(name);
        let staged = target.with_extension("desktop.new");
        fs::write(&staged, switched(&text, on))?;
        fs::rename(&staged, &target)
    }

    /// The entry's untranslated `Name` and its `Exec` line.
    pub(super) fn name_and_command(text: &str) -> (Option<String>, Option<String>) {
        let (mut in_entry, mut name, mut command) = (false, None, None);
        for line in text.lines().map(str::trim) {
            if line.starts_with('[') {
                in_entry = line == "[Desktop Entry]";
                continue;
            }
            let Some((key, value)) = line.split_once('=') else { continue };
            match (in_entry, key.trim()) {
                (true, "Name") if name.is_none() => name = Some(value.trim().to_owned()),
                (true, "Exec") if command.is_none() => command = Some(value.trim().to_owned()),
                _ => {}
            }
        }
        (name, command)
    }

    /// The account's folder first, then the system's; an account's entry
    /// replaces the system's of the same file name. Without the account's
    /// folder there's nowhere to keep a change, so nothing is listed.
    pub(super) fn read_folders(folders: &[(PathBuf, &str)]) -> Vec<StartupItem> {
        let Some((account_folder, _)) = folders.first() else { return Vec::new() };
        let mut seen = HashSet::new();
        let mut items = Vec::new();
        for (folder, title) in folders {
            let Ok(entries) = fs::read_dir(folder) else { continue };
            let mut files: Vec<PathBuf> = entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|extension| extension == "desktop"))
                .collect();
            files.sort();
            for file in files {
                let Some(file_name) = file.file_name().map(|name| name.to_os_string()) else { continue };
                if !seen.insert(file_name) {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&file) else { continue };
                let (name, command) = name_and_command(&text);
                items.push(StartupItem {
                    name: name.unwrap_or_else(|| stem(&file)),
                    command: command.unwrap_or_else(|| file.display().to_string()),
                    source: (*title).to_owned(),
                    enabled: desktop_entry_enabled(&text),
                    switch: Switch { file: file.clone(), account_folder: account_folder.clone() },
                });
            }
        }
        items
    }

    fn folders() -> Vec<(PathBuf, &'static str)> {
        let Some(place) = crate::autostart::Place::user() else { return Vec::new() };
        let mut folders = vec![(place.folder, "Your autostart folder")];
        let system = std::env::var("XDG_CONFIG_DIRS").ok().filter(|dirs| !dirs.is_empty());
        for dir in system.as_deref().unwrap_or("/etc/xdg").split(':').filter(|dir| Path::new(dir).is_absolute()) {
            folders.push((Path::new(dir).join("autostart"), "System autostart folder"));
        }
        folders
    }

    pub fn read() -> Vec<StartupItem> {
        read_folders(&folders())
    }
}

#[cfg(test)]
mod tests {
    use super::{StartupItem, Switch, matches, set_enabled};

    #[test]
    fn searches_names_and_commands() {
        let item = StartupItem {
            name: "Steam".to_owned(),
            command: "\"C:\\Program Files\\Steam\\steam.exe\" -silent".to_owned(),
            source: "Your Run key".to_owned(),
            enabled: true,
            switch: Switch::placeholder(),
        };
        assert!(matches(&item, "steam"));
        assert!(matches(&item, "SILENT"));
        assert!(!matches(&item, "discord"));
        assert!(matches(&item, " "));
    }

    #[cfg(windows)]
    #[test]
    fn lists_run_values_and_folder_files_with_task_managers_switch() {
        use super::platform::{Place, Source, read_sources};
        use crate::registry::{Hive, delete_tree, write_binary, write_string};
        let root = format!(r"Software\OpenTaskManager-tests-{}-startup", std::process::id());
        let folder = std::env::temp_dir().join(format!("otm-startup-test-{}", std::process::id()));
        std::fs::create_dir_all(&folder).expect("a folder");
        std::fs::write(folder.join("Notes.lnk"), b"").expect("a shortcut");
        std::fs::write(folder.join("desktop.ini"), b"").expect("Explorer's file");
        write_string(Hive::User, &format!(r"{root}\Run"), "Tool", r"C:\Tools\tool.exe --quiet").expect("a value");
        write_string(Hive::User, &format!(r"{root}\Run"), "Off", r"C:\Off.exe").expect("a value");
        write_binary(Hive::User, &format!(r"{root}\Approved"), "Off", &[3, 0, 0, 0]).expect("turned off");
        let sources = [
            Source {
                title: "Test key",
                place: Place::Key { hive: Hive::User, key: format!(r"{root}\Run") },
                approved: (Hive::User, format!(r"{root}\Approved")),
            },
            Source {
                title: "Test folder",
                place: Place::Folder(folder.clone()),
                approved: (Hive::User, format!(r"{root}\Approved")),
            },
        ];
        let mut items = read_sources(&sources);
        items.sort_by(|a, b| a.name.cmp(&b.name));
        let _ = delete_tree(Hive::User, &root);
        let _ = std::fs::remove_dir_all(&folder);
        let summary: Vec<(&str, &str, bool)> =
            items.iter().map(|item| (item.name.as_str(), item.source.as_str(), item.enabled)).collect();
        assert_eq!(summary, [("Notes", "Test folder", true), ("Off", "Test key", false), ("Tool", "Test key", true)]);
        assert!(items[2].command.ends_with("--quiet"));
    }

    #[cfg(not(windows))]
    #[test]
    fn an_accounts_entry_replaces_the_systems_and_hidden_ones_are_off() {
        use super::platform::read_folders;
        let root = std::env::temp_dir().join(format!("otm-startup-test-{}", std::process::id()));
        let (user, system) = (root.join("user"), root.join("system"));
        std::fs::create_dir_all(&user).expect("a folder");
        std::fs::create_dir_all(&system).expect("a folder");
        let entry = |name: &str, more: &str| {
            format!("[Desktop Entry]\nType=Application\nName={name}\nExec={name} --start\n{more}")
        };
        std::fs::write(system.join("tracker.desktop"), entry("Tracker", "")).expect("written");
        std::fs::write(user.join("tracker.desktop"), entry("Tracker", "Hidden=true\n")).expect("written");
        std::fs::write(system.join("agent.desktop"), entry("Agent", "")).expect("written");
        std::fs::write(user.join("notes.txt"), "not an entry").expect("written");
        let items = read_folders(&[(user, "Yours"), (system, "System")]);
        let _ = std::fs::remove_dir_all(&root);
        let summary: Vec<(&str, &str, bool)> =
            items.iter().map(|item| (item.name.as_str(), item.source.as_str(), item.enabled)).collect();
        assert_eq!(summary, [("Tracker", "Yours", false), ("Agent", "System", true)]);
        assert_eq!(items[1].command, "Agent --start");
    }

    #[cfg(windows)]
    #[test]
    fn turns_an_item_off_and_on_with_explorers_mark() {
        use super::platform::{Place, Source, read_sources};
        use crate::registry::{Hive, delete_tree, write_string};
        let root = format!(r"Software\OpenTaskManager-tests-{}-startup-switch", std::process::id());
        write_string(Hive::User, &format!(r"{root}\Run"), "Tool", r"C:\Tools\tool.exe").expect("a value");
        let sources = [Source {
            title: "Test key",
            place: Place::Key { hive: Hive::User, key: format!(r"{root}\Run") },
            approved: (Hive::User, format!(r"{root}\Approved")),
        }];
        let item = read_sources(&sources).remove(0);
        assert!(item.enabled);
        set_enabled(&item, false).expect("turned off");
        let off = read_sources(&sources)[0].enabled;
        set_enabled(&item, true).expect("turned on");
        let on = read_sources(&sources)[0].enabled;
        let command = crate::registry::read_string(Hive::User, &format!(r"{root}\Run"), "Tool");
        let _ = delete_tree(Hive::User, &root);
        assert!(!off, "off, as Task Manager would read it");
        assert!(on, "on again");
        assert_eq!(command.as_deref(), Some(r"C:\Tools\tool.exe"), "the Run value itself is left alone");
    }

    #[cfg(windows)]
    #[test]
    fn marks_as_task_manager_does() {
        use std::time::{Duration, UNIX_EPOCH};
        let on = super::platform::mark(true, UNIX_EPOCH);
        assert_eq!(on, [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let off = super::platform::mark(false, UNIX_EPOCH + Duration::from_secs(1));
        assert_eq!(off[..4], [3, 0, 0, 0]);
        let filetime = u64::from_le_bytes(off[4..].try_into().expect("eight bytes"));
        assert_eq!(filetime, (11_644_473_600 + 1) * 10_000_000, "100 ns steps since 1601");
    }

    #[cfg(not(windows))]
    #[test]
    fn turns_a_system_entry_off_and_on_through_an_account_copy() {
        use super::platform::read_folders;
        let root = std::env::temp_dir().join(format!("otm-startup-switch-{}", std::process::id()));
        let (user, system) = (root.join("user"), root.join("system"));
        std::fs::create_dir_all(&system).expect("a folder");
        let original = "[Desktop Entry]\nName=Tool\nExec=tool\n";
        std::fs::write(system.join("tool.desktop"), original).expect("written");
        let folders = [(user.clone(), "Yours"), (system.clone(), "System")];
        let item = read_folders(&folders).remove(0);
        assert!(item.enabled && item.source == "System");
        set_enabled(&item, false).expect("turned off");
        let off = read_folders(&folders).remove(0);
        set_enabled(&off, true).expect("turned on");
        let on = read_folders(&folders).remove(0);
        let untouched = std::fs::read_to_string(system.join("tool.desktop")).expect("still there");
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!((off.enabled, off.source.as_str()), (false, "Yours"), "the account's copy replaces the system's");
        assert!(on.enabled);
        assert_eq!(untouched, original, "the system's entry is never changed");
    }

    #[cfg(not(windows))]
    #[test]
    fn switching_an_entry_sets_or_clears_its_off_keys() {
        use super::platform::switched;
        let entry = "[Desktop Entry]\nName=Tool\nHidden=false\nExec=tool\n[Desktop Action new]\nHidden=true\n";
        let off = switched(entry, false);
        assert_eq!(
            off,
            "[Desktop Entry]\nHidden=true\nX-GNOME-Autostart-enabled=false\nName=Tool\nExec=tool\n[Desktop Action new]\nHidden=true\n"
        );
        assert_eq!(switched(&off, true), "[Desktop Entry]\nName=Tool\nExec=tool\n[Desktop Action new]\nHidden=true\n");
    }

    #[cfg(not(windows))]
    #[test]
    fn reads_the_untranslated_name_and_exec_of_the_main_group() {
        use super::platform::name_and_command;
        let text =
            "[Desktop Entry]\nName[de]=Werkzeug\nName=Tool\nExec=tool %U\n[Desktop Action new]\nExec=tool --new\n";
        assert_eq!(name_and_command(text), (Some("Tool".to_owned()), Some("tool %U".to_owned())));
    }
}
