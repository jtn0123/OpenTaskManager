//! Starting OpenTaskManager at sign-in, hidden in the tray, the way each
//! system expects: a value in the account's Run key on Windows, a desktop
//! entry in the account's autostart folder on Linux. Nothing needs
//! administrator rights.

use std::io;
use std::path::Path;

use crate::instance::DEFAULT;

/// The arguments a sign-in launch gets: hidden, under the same instance.
fn arguments(instance: &str) -> Vec<String> {
    let mut arguments = vec!["--hidden".to_owned()];
    if instance != DEFAULT {
        arguments.extend(["--instance".to_owned(), instance.to_owned()]);
    }
    arguments
}

#[cfg(windows)]
pub use self::windows::{Place, disable, enable, is_enabled};

#[cfg(not(windows))]
pub use self::xdg::{Place, disable, enable, is_enabled};

#[cfg(windows)]
mod windows {
    use std::io;
    use std::path::Path;

    use super::arguments;
    use crate::registry::{self, Hive};

    /// Where the entry goes: the account's own Run key, and Explorer's
    /// record of entries the user turned off in Task Manager.
    pub struct Place {
        pub run: String,
        pub approved: String,
    }

    impl Place {
        pub fn user() -> Option<Place> {
            Some(Place {
                run: r"Software\Microsoft\Windows\CurrentVersion\Run".to_owned(),
                approved: r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run".to_owned(),
            })
        }
    }

    fn value_name(instance: &str) -> String {
        if instance == crate::instance::DEFAULT {
            "OpenTaskManager".to_owned()
        } else {
            format!("OpenTaskManager ({instance})")
        }
    }

    /// Whether Windows will start it at sign-in: the value is there and
    /// Task Manager's Startup page hasn't turned it off.
    pub fn is_enabled(place: &Place, instance: &str) -> bool {
        let name = value_name(instance);
        registry::read_string(Hive::User, &place.run, &name).is_some()
            && !registry::read_binary(Hive::User, &place.approved, &name).is_some_and(|state| turned_off(&state))
    }

    /// Explorer marks a turned-off entry with an odd first byte (2 and 6 are on).
    pub(crate) fn turned_off(state: &[u8]) -> bool {
        state.first().is_some_and(|first| first & 1 == 1)
    }

    pub fn enable(place: &Place, instance: &str, exe: &Path) -> io::Result<()> {
        let name = value_name(instance);
        let mut command = format!("\"{}\"", exe.display());
        for argument in arguments(instance) {
            command.push(' ');
            command.push_str(&argument);
        }
        registry::write_string(Hive::User, &place.run, &name, &command)?;
        // A turned-off mark from an earlier entry would keep this one off.
        registry::delete_value(Hive::User, &place.approved, &name)
    }

    pub fn disable(place: &Place, instance: &str) -> io::Result<()> {
        let name = value_name(instance);
        registry::delete_value(Hive::User, &place.run, &name)?;
        registry::delete_value(Hive::User, &place.approved, &name)
    }
}

#[cfg(not(windows))]
mod xdg {
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};

    use super::arguments;

    /// The account's autostart folder.
    pub struct Place {
        pub folder: PathBuf,
    }

    impl Place {
        pub fn user() -> Option<Place> {
            let config = std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
            Some(Place { folder: config.join("autostart") })
        }

        fn file(&self, instance: &str) -> PathBuf {
            if instance == crate::instance::DEFAULT {
                self.folder.join("opentaskmanager.desktop")
            } else {
                self.folder.join(format!("opentaskmanager-{instance}.desktop"))
            }
        }
    }

    /// Whether the desktop will start it: the entry is there and isn't hidden or turned off.
    pub fn is_enabled(place: &Place, instance: &str) -> bool {
        fs::read_to_string(place.file(instance)).is_ok_and(|text| desktop_entry_enabled(&text))
    }

    pub fn enable(place: &Place, instance: &str, exe: &Path) -> io::Result<()> {
        fs::create_dir_all(&place.folder)?;
        let mut exec = exec_argument(&exe.to_string_lossy());
        for argument in arguments(instance) {
            exec.push(' ');
            exec.push_str(&argument);
        }
        let entry = format!(
            "[Desktop Entry]\nType=Application\nName=OpenTaskManager\nComment=Starts hidden in the tray\n\
             Exec={exec}\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
        );
        let file = place.file(instance);
        let staged = file.with_extension("desktop.new");
        fs::write(&staged, entry)?;
        fs::rename(&staged, &file)
    }

    pub fn disable(place: &Place, instance: &str) -> io::Result<()> {
        match fs::remove_file(place.file(instance)) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    /// Whether a desktop entry would start: not `Hidden`, and not turned off
    /// with GNOME's `X-GNOME-Autostart-enabled`.
    pub(crate) fn desktop_entry_enabled(text: &str) -> bool {
        let mut in_entry = false;
        for line in text.lines().map(str::trim) {
            if line.starts_with('[') {
                in_entry = line == "[Desktop Entry]";
                continue;
            }
            let Some((key, value)) = line.split_once('=') else { continue };
            match (in_entry, key.trim(), value.trim()) {
                (true, "Hidden", "true") | (true, "X-GNOME-Autostart-enabled", "false") => return false,
                _ => {}
            }
        }
        true
    }

    /// One Exec argument, quoted as the desktop entry spec asks: `"`, `` ` ``,
    /// `$` and `\` escaped inside the quotes, `%` doubled, then every
    /// backslash doubled again because the value itself is an escaped string.
    pub(crate) fn exec_argument(argument: &str) -> String {
        let mut quoted = String::from("\"");
        for character in argument.chars() {
            match character {
                '"' | '`' | '$' | '\\' => {
                    quoted.push('\\');
                    quoted.push(character);
                }
                '%' => quoted.push_str("%%"),
                _ => quoted.push(character),
            }
        }
        quoted.push('"');
        quoted.replace('\\', "\\\\")
    }
}

/// The account's own place, where `enable` writes.
pub fn user_place() -> io::Result<Place> {
    Place::user().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no settings folder for this account"))
}

/// Turns starting at sign-in on or off for this program, for `instance`.
pub fn set(instance: &str, on: bool) -> io::Result<()> {
    let place = user_place()?;
    if on {
        let exe = std::env::current_exe()?;
        enable(&place, instance, Path::new(&exe))
    } else {
        disable(&place, instance)
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{Place, disable, enable, is_enabled};

    #[cfg(windows)]
    fn place(test: &str) -> (Place, impl Drop) {
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = crate::registry::delete_tree(crate::registry::Hive::User, &self.0);
            }
        }
        let root = format!(r"Software\OpenTaskManager-tests-{}-{test}", std::process::id());
        let place = Place { run: format!(r"{root}\Run"), approved: format!(r"{root}\StartupApproved\Run") };
        (place, Cleanup(root))
    }

    #[cfg(not(windows))]
    fn place(test: &str) -> (Place, impl Drop) {
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let root = std::env::temp_dir().join(format!("otm-autostart-test-{}-{test}", std::process::id()));
        (Place { folder: root.join("autostart") }, Cleanup(root))
    }

    #[test]
    fn turns_on_and_off_for_one_instance_only() {
        let (place, _cleanup) = place("turns");
        let exe = Path::new(if cfg!(windows) { r"C:\Program Files\OTM\opentaskmanager.exe" } else { "/opt/otm/otm" });
        assert!(!is_enabled(&place, "default"));
        enable(&place, "smoke-1", exe).expect("enabled");
        assert!(is_enabled(&place, "smoke-1"));
        assert!(!is_enabled(&place, "default"), "another instance's entry is separate");
        disable(&place, "smoke-1").expect("disabled");
        assert!(!is_enabled(&place, "smoke-1"));
        disable(&place, "smoke-1").expect("turning off twice is fine");
    }

    #[cfg(windows)]
    #[test]
    fn writes_a_quoted_command_and_respects_task_managers_switch() {
        use crate::registry::{Hive, read_string, write_binary};
        let (place, _cleanup) = place("quoted");
        let exe = Path::new(r"C:\Program Files\OTM\opentaskmanager.exe");
        enable(&place, "default", exe).expect("enabled");
        assert_eq!(
            read_string(Hive::User, &place.run, "OpenTaskManager").as_deref(),
            Some(r#""C:\Program Files\OTM\opentaskmanager.exe" --hidden"#)
        );
        write_binary(Hive::User, &place.approved, "OpenTaskManager", &[3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            .expect("turned off as Task Manager would");
        assert!(!is_enabled(&place, "default"), "turned off in Task Manager");
        enable(&place, "default", exe).expect("on again");
        assert!(is_enabled(&place, "default"), "turning it on here clears Task Manager's mark");
    }

    #[cfg(not(windows))]
    #[test]
    fn writes_a_desktop_entry_with_a_quoted_exec_line() {
        let (place, _cleanup) = place("entry");
        enable(&place, "smoke-1", Path::new("/opt/my apps/o$t%m")).expect("enabled");
        let text = std::fs::read_to_string(place.folder.join("opentaskmanager-smoke-1.desktop")).expect("written");
        assert!(text.contains("Exec=\"/opt/my apps/o\\\\$t%%m\" --hidden --instance smoke-1\n"), "{text}");
        assert!(text.starts_with("[Desktop Entry]\n"));
    }

    #[cfg(not(windows))]
    #[test]
    fn reads_whether_a_desktop_entry_starts() {
        use super::xdg::desktop_entry_enabled;
        assert!(desktop_entry_enabled("[Desktop Entry]\nExec=x\n"));
        assert!(!desktop_entry_enabled("[Desktop Entry]\nHidden=true\n"));
        assert!(!desktop_entry_enabled("[Desktop Entry]\nX-GNOME-Autostart-enabled=false\n"));
        assert!(desktop_entry_enabled("[Desktop Action x]\nHidden=true\n[Desktop Entry]\nExec=x\n"));
    }

    #[cfg(not(windows))]
    #[test]
    fn quotes_exec_arguments_as_the_spec_asks() {
        use super::xdg::exec_argument;
        assert_eq!(exec_argument("/usr/bin/otm"), "\"/usr/bin/otm\"");
        assert_eq!(exec_argument("a\"b"), "\"a\\\\\"b\"");
        assert_eq!(exec_argument("a\\b"), "\"a\\\\\\\\b\"");
        assert_eq!(exec_argument("100%"), "\"100%%\"");
    }
}
