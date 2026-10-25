//! What starts at sign-in, as the system's own lists give it: on Windows
//! the Run keys and Startup folders, each item on or off as Task Manager's
//! Startup page last left it; on Linux the XDG autostart folders, an
//! account's entry replacing the system's of the same name. Read when the
//! Startup page opens or is refreshed, never per tick, and never changed.

use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartupItem {
    pub name: String,
    /// The command it runs, or the file it opens.
    pub command: String,
    /// Where it's listed, in words.
    pub source: String,
    /// Whether it will start at the next sign-in.
    pub enabled: bool,
}

/// Every item, by name.
pub fn read() -> Vec<StartupItem> {
    let mut items = platform::read();
    items.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then(a.source.cmp(&b.source)));
    items
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
    use std::path::PathBuf;

    use super::{StartupItem, stem};
    use crate::autostart::turned_off;
    use crate::registry::{self, Hive};

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
            match &source.place {
                Place::Key { hive, key } => {
                    for (name, command) in registry::strings(*hive, key) {
                        items.push(StartupItem {
                            enabled: enabled(&name),
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
    use std::path::{Path, PathBuf};

    use super::{StartupItem, stem};
    use crate::autostart::desktop_entry_enabled;

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
    /// replaces the system's of the same file name.
    pub(super) fn read_folders(folders: &[(PathBuf, &str)]) -> Vec<StartupItem> {
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
                });
            }
        }
        items
    }

    fn folders() -> Vec<(PathBuf, &'static str)> {
        let mut folders = Vec::new();
        if let Some(place) = crate::autostart::Place::user() {
            folders.push((place.folder, "Your autostart folder"));
        }
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
    use super::{StartupItem, matches};

    #[test]
    fn searches_names_and_commands() {
        let item = StartupItem {
            name: "Steam".to_owned(),
            command: "\"C:\\Program Files\\Steam\\steam.exe\" -silent".to_owned(),
            source: "Your Run key".to_owned(),
            enabled: true,
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

    #[cfg(not(windows))]
    #[test]
    fn reads_the_untranslated_name_and_exec_of_the_main_group() {
        use super::platform::name_and_command;
        let text =
            "[Desktop Entry]\nName[de]=Werkzeug\nName=Tool\nExec=tool %U\n[Desktop Action new]\nExec=tool --new\n";
        assert_eq!(name_and_command(text), (Some("Tool".to_owned()), Some("tool %U".to_owned())));
    }
}
