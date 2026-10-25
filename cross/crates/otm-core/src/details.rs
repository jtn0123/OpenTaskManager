//! What the details panel shows beyond the table's figures: a process's
//! program file and command line. Read for one process when it's selected,
//! never each tick, and only if it's still the process that was selected.

use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

use crate::model::ProcessKey;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Details {
    /// The program file, when the system lets this account read it.
    pub path: Option<String>,
    /// The command line, its arguments quoted where they hold spaces.
    pub command: Option<String>,
}

/// Reads `key`'s details, or None when it has ended or its PID now names another process.
pub fn read(key: ProcessKey) -> Option<Details> {
    let pid = sysinfo::Pid::from_u32(key.pid);
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[pid]),
        true,
        ProcessRefreshKind::nothing().with_exe(UpdateKind::Always).with_cmd(UpdateKind::Always),
    );
    let process = system.process(pid).filter(|process| process.start_time() == key.start_time)?;
    let arguments: Vec<String> = process.cmd().iter().map(|argument| argument.to_string_lossy().into_owned()).collect();
    Some(Details {
        path: process.exe().map(|path| path.display().to_string()).filter(|path| !path.is_empty()),
        command: (!arguments.is_empty()).then(|| command_line(&arguments)),
    })
}

/// Arguments joined as a shell would read them back: quoted where they hold spaces.
pub fn command_line(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|argument| {
            if argument.is_empty() || argument.contains(char::is_whitespace) {
                format!("\"{argument}\"")
            } else {
                argument.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::{command_line, read};
    use crate::model::ProcessKey;

    #[test]
    fn quotes_arguments_with_spaces() {
        let arguments = ["C:\\Program Files\\x.exe", "--flag", "", "two words"].map(str::to_owned);
        assert_eq!(command_line(&arguments), "\"C:\\Program Files\\x.exe\" --flag \"\" \"two words\"");
    }

    /// Live: this test's own process.
    #[test]
    fn reads_this_process_and_refuses_another_start_time() {
        let pid = sysinfo::Pid::from_u32(std::process::id());
        let mut system = sysinfo::System::new();
        system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&[pid]), true);
        let start_time = system.process(pid).expect("this process").start_time();
        let key = ProcessKey { pid: std::process::id(), start_time };
        let details = read(key).expect("its details");
        let exe = std::env::current_exe().expect("this test's file");
        let name = exe.file_name().expect("a file name").to_string_lossy().into_owned();
        assert!(details.path.as_deref().is_some_and(|path| path.ends_with(&name)), "{details:?}");
        assert!(details.command.is_some_and(|command| command.contains(&name)));
        assert_eq!(read(ProcessKey { start_time: start_time + 5, ..key }), None);
    }
}
