//! Ending a process: the one a row showed, never another that has since
//! taken its PID. The identity check and the action go through the same
//! kernel handle (a pidfd on Linux, a process handle on Windows), so a PID
//! the system reuses in between can't receive the action. Start times are
//! compared to the second, as the table records them.

use crate::model::ProcessKey;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ending {
    /// Ask it to quit: SIGTERM on Linux; on Windows, close its windows, as
    /// clicking their close buttons would.
    Ask,
    /// End it now (SIGKILL, or TerminateProcess). Unsaved work is lost.
    Force,
}

/// Why nothing was done.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The process had already ended.
    Ended,
    /// The PID now belongs to a process started at another time.
    Replaced,
    /// The system won't let this account act on it: another account's
    /// process, or a protected one.
    NotPermitted,
    /// It has no window to close, so only Force Quit can end it.
    NoWindow,
    /// OpenTaskManager itself.
    Itself,
    /// This system has no supported way to do it.
    Unsupported,
    /// The system refused for another reason, as it described it.
    Failed(String),
}

/// Ends the process `key` names, if it's still the one that was shown.
pub fn end(key: ProcessKey, how: Ending) -> Result<(), Refusal> {
    if key.pid == std::process::id() {
        return Err(Refusal::Itself);
    }
    platform::end(key, how)
}

/// What Force Quit asks first, in the Mac app's words, with the target named
/// as it was when the question opened.
pub fn confirmation(name: &str, key: ProcessKey) -> String {
    format!(
        concat!(
            "Force quit {name} (PID {pid})? It stops at once, and any unsaved work in it is lost. ",
            "End Task asks it to quit instead, so it can save first."
        ),
        name = name,
        pid = key.pid
    )
}

/// What to tell the user about `end`'s outcome for the process called `name`.
pub fn describe(name: &str, key: ProcessKey, how: Ending, outcome: &Result<(), Refusal>) -> String {
    let who = format!("{name} (PID {})", key.pid);
    match outcome {
        Ok(()) if how == Ending::Ask => format!("Asked {who} to quit."),
        Ok(()) => format!("Ended {who} at once."),
        Err(Refusal::Ended) => format!("{who} had already ended."),
        Err(Refusal::Replaced) => format!("PID {} now belongs to another process, so nothing was done.", key.pid),
        Err(Refusal::NotPermitted) => {
            format!("{who} belongs to another account or is protected; ending it needs administrator rights.")
        }
        Err(Refusal::NoWindow) => format!("{who} has no window to close. Force Quit ends it."),
        Err(Refusal::Itself) => "That's OpenTaskManager itself: quit it from its tray menu.".to_owned(),
        Err(Refusal::Unsupported) => "Ending processes isn't supported on this system yet.".to_owned(),
        Err(Refusal::Failed(reason)) => format!("Couldn't end {who}: {reason}."),
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use rustix::io::Errno;
    use rustix::process::{Pid, PidfdFlags, Signal, pidfd_open, pidfd_send_signal};
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};

    use super::{Ending, ProcessKey, Refusal};

    pub fn end(key: ProcessKey, how: Ending) -> Result<(), Refusal> {
        let pid = i32::try_from(key.pid).ok().and_then(Pid::from_raw).ok_or(Refusal::Ended)?;
        // Hold the process first, then check it's the one the row showed:
        // the signal goes through this handle, so a reused PID can't receive it.
        let process = pidfd_open(pid, PidfdFlags::empty()).map_err(refusal)?;
        if start_time(key.pid).ok_or(Refusal::Ended)? != key.start_time {
            return Err(Refusal::Replaced);
        }
        let signal = match how {
            Ending::Ask => Signal::TERM,
            Ending::Force => Signal::KILL,
        };
        pidfd_send_signal(&process, signal).map_err(refusal)
    }

    /// Read as the sampler reads it, so the two compare exactly.
    fn start_time(pid: u32) -> Option<u64> {
        let pid = sysinfo::Pid::from_u32(pid);
        let mut system = System::new();
        system.refresh_processes_specifics(ProcessesToUpdate::Some(&[pid]), true, ProcessRefreshKind::nothing());
        system.process(pid).map(sysinfo::Process::start_time)
    }

    fn refusal(error: Errno) -> Refusal {
        match error {
            Errno::SRCH => Refusal::Ended,
            Errno::PERM | Errno::ACCESS => Refusal::NotPermitted,
            Errno::NOSYS => Refusal::Unsupported,
            other => Refusal::Failed(other.to_string()),
        }
    }
}

#[cfg(windows)]
mod platform {
    use windows_sys::Win32::Foundation::{
        CloseHandle, ERROR_ACCESS_DENIED, ERROR_INVALID_PARAMETER, FILETIME, GetLastError, HANDLE, HWND, LPARAM,
        WAIT_FAILED, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
        TerminateProcess, WaitForSingleObject,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowThreadProcessId, IsWindowVisible, PostMessageW, WM_CLOSE,
    };
    use windows_sys::core::BOOL;

    use super::{Ending, ProcessKey, Refusal};

    /// An open process handle, closed when dropped. While it's open,
    /// Windows can't give the process's PID to another.
    struct Process(HANDLE);

    impl Drop for Process {
        fn drop(&mut self) {
            // SAFETY: the handle came from OpenProcess and is closed only here, once.
            unsafe { CloseHandle(self.0) };
        }
    }

    fn last_refusal() -> Refusal {
        // SAFETY: reads the calling thread's last-error value; no pointers involved.
        match unsafe { GetLastError() } {
            ERROR_INVALID_PARAMETER => Refusal::Ended,
            ERROR_ACCESS_DENIED => Refusal::NotPermitted,
            code => Refusal::Failed(format!("Windows error {code}")),
        }
    }

    pub fn end(key: ProcessKey, how: Ending) -> Result<(), Refusal> {
        let rights = PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE;
        // SAFETY: plain values in; a null handle is checked before use.
        let handle = unsafe { OpenProcess(rights, 0, key.pid) };
        if handle.is_null() {
            return Err(last_refusal());
        }
        let process = Process(handle);
        if start_time(&process)? != key.start_time {
            return Err(Refusal::Replaced);
        }
        // A process that has ended but whose handle something still holds keeps its PID: a
        // zero wait tells it from a running one (its exit code can't: 259 is a real code too).
        // SAFETY: the handle is open with synchronize rights; a zero timeout never blocks.
        match unsafe { WaitForSingleObject(process.0, 0) } {
            WAIT_TIMEOUT => {}
            WAIT_FAILED => return Err(last_refusal()),
            _ => return Err(Refusal::Ended),
        }
        match how {
            Ending::Force => {
                // SAFETY: the handle is open with terminate rights.
                if unsafe { TerminateProcess(process.0, 1) } == 0 {
                    return Err(last_refusal());
                }
                Ok(())
            }
            // Its windows are found while the handle keeps the PID from being reused.
            Ending::Ask => close_windows(key.pid),
        }
    }

    /// Creation time in seconds since 1970, as `sysinfo` computes it.
    fn start_time(process: &Process) -> Result<u64, Refusal> {
        let empty = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let (mut created, mut exited, mut kernel, mut user) = (empty, empty, empty, empty);
        // SAFETY: the handle is open with query rights; all four outputs outlive the call.
        if unsafe { GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user) } == 0 {
            return Err(last_refusal());
        }
        let hundreds_of_ns = (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime);
        // Seconds from 1601, Windows' epoch, to 1970.
        Ok((hundreds_of_ns / 10_000_000).saturating_sub(11_644_473_600))
    }

    struct Search {
        pid: u32,
        windows: Vec<HWND>,
    }

    unsafe extern "system" fn collect(window: HWND, data: LPARAM) -> BOOL {
        // SAFETY: `data` is the `&mut Search` close_windows passes, alive for the whole enumeration.
        let search = unsafe { &mut *(data as *mut Search) };
        let mut owner = 0u32;
        // SAFETY: `window` comes from EnumWindows; `owner` outlives the call.
        unsafe { GetWindowThreadProcessId(window, &mut owner) };
        // SAFETY: as above.
        if owner == search.pid && unsafe { IsWindowVisible(window) } != 0 {
            search.windows.push(window);
        }
        1
    }

    fn close_windows(pid: u32) -> Result<(), Refusal> {
        let mut search = Search { pid, windows: Vec::new() };
        // SAFETY: `collect` only uses `search` during this call, which outlives it.
        unsafe { EnumWindows(Some(collect), &mut search as *mut Search as LPARAM) };
        if search.windows.is_empty() {
            return Err(Refusal::NoWindow);
        }
        for window in search.windows {
            // SAFETY: posting WM_CLOSE takes no pointers; a window that closed meanwhile just fails.
            unsafe { PostMessageW(window, WM_CLOSE, 0, 0) };
        }
        Ok(())
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use super::{Ending, ProcessKey, Refusal};

    pub fn end(_key: ProcessKey, _how: Ending) -> Result<(), Refusal> {
        Err(Refusal::Unsupported)
    }
}

#[cfg(test)]
mod tests {
    use std::process::{Child, Command, Stdio};
    use std::thread::sleep;
    use std::time::{Duration, Instant};

    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};

    use super::{Ending, Refusal, confirmation, describe, end};
    use crate::model::ProcessKey;

    /// A harmless process that waits two minutes unless ended.
    fn waiter() -> Child {
        #[cfg(windows)]
        let mut command = {
            let mut command = Command::new("ping");
            command.args(["-n", "120", "127.0.0.1"]);
            command
        };
        #[cfg(not(windows))]
        let mut command = {
            let mut command = Command::new("sleep");
            command.arg("120");
            command
        };
        command.stdout(Stdio::null()).spawn().expect("a process to end")
    }

    /// The key the table would show for `child`.
    fn key_of(child: &Child) -> ProcessKey {
        key_of_pid(child.id())
    }

    fn key_of_pid(pid: u32) -> ProcessKey {
        let id = sysinfo::Pid::from_u32(pid);
        let mut system = System::new();
        system.refresh_processes_specifics(ProcessesToUpdate::Some(&[id]), true, ProcessRefreshKind::nothing());
        let start_time = system.process(id).expect("a running process").start_time();
        ProcessKey { pid, start_time }
    }

    fn exits_within(child: &mut Child, limit: Duration) -> bool {
        let started = Instant::now();
        while started.elapsed() < limit {
            if child.try_wait().expect("the child's status").is_some() {
                return true;
            }
            sleep(Duration::from_millis(50));
        }
        false
    }

    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn force_ends_the_process_it_was_shown() {
        let mut child = waiter();
        assert_eq!(end(key_of(&child), Ending::Force), Ok(()));
        assert!(exits_within(&mut child, Duration::from_secs(5)));
    }

    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn a_pid_now_started_at_another_time_is_refused_and_left_running() {
        let mut child = waiter();
        let mut key = key_of(&child);
        key.start_time -= 7;
        assert_eq!(end(key, Ending::Force), Err(Refusal::Replaced));
        assert!(child.try_wait().expect("status").is_none(), "the process still runs");
        child.kill().expect("cleanup");
        child.wait().expect("cleanup");
    }

    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn an_ended_process_is_reported_as_ended() {
        let mut child = waiter();
        let key = key_of(&child);
        child.kill().expect("end it first");
        child.wait().expect("reaped");
        let outcome = end(key, Ending::Force);
        // In the instant since, the system may already have given the PID to another process.
        assert!(matches!(outcome, Err(Refusal::Ended | Refusal::Replaced)), "{outcome:?}");
    }

    #[test]
    fn refuses_to_end_itself() {
        let key = ProcessKey { pid: std::process::id(), start_time: 0 };
        assert_eq!(end(key, Ending::Force), Err(Refusal::Itself));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn asking_sends_sigterm() {
        use std::os::unix::process::ExitStatusExt;
        let mut child = waiter();
        assert_eq!(end(key_of(&child), Ending::Ask), Ok(()));
        let status = child.wait().expect("it ends");
        assert_eq!(status.signal(), Some(15));
    }

    /// PID 1 is root's. Run as root this would signal it, so it only runs as another account.
    #[cfg(target_os = "linux")]
    #[test]
    fn another_accounts_process_is_not_permitted() {
        if rustix::process::geteuid().is_root() {
            return;
        }
        assert_eq!(end(key_of_pid(1), Ending::Ask), Err(Refusal::NotPermitted));
    }

    /// No account can open Windows' System process (PID 4) to end it, administrators included.
    #[cfg(windows)]
    #[test]
    fn the_system_process_is_not_permitted() {
        assert_eq!(end(ProcessKey { pid: 4, start_time: 0 }, Ending::Force), Err(Refusal::NotPermitted));
    }

    #[cfg(windows)]
    #[test]
    fn asking_a_process_without_windows_says_force_quit_is_needed() {
        let mut child = waiter();
        assert_eq!(end(key_of(&child), Ending::Ask), Err(Refusal::NoWindow));
        assert!(child.try_wait().expect("status").is_none(), "the process still runs");
        child.kill().expect("cleanup");
        child.wait().expect("cleanup");
    }

    /// A window that's shown but never seen: transparent, off screen, out of
    /// the taskbar and never activated, so it takes no one's focus. It closes
    /// itself after a minute if the test fails to.
    #[cfg(windows)]
    const QUIET_WINDOW: &str = r#"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class QuietForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
}
'@
$form = New-Object QuietForm
$form.ShowInTaskbar = $false
$form.Opacity = 0
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-32000, -32000)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.add_Tick({ $form.Close() })
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
"#;

    #[cfg(windows)]
    #[test]
    fn asking_closes_the_windows_of_a_process_that_has_some() {
        let script = std::env::temp_dir().join(format!("otm-quiet-window-{}.ps1", std::process::id()));
        std::fs::write(&script, QUIET_WINDOW).expect("the script");
        let mut child = Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&script)
            .stdout(Stdio::null())
            .spawn()
            .expect("PowerShell");
        let key = key_of(&child);
        // The window appears once PowerShell has started and built the form.
        let started = Instant::now();
        let outcome = loop {
            let outcome = end(key, Ending::Ask);
            if outcome != Err(Refusal::NoWindow) || started.elapsed() > Duration::from_secs(30) {
                break outcome;
            }
            sleep(Duration::from_millis(200));
        };
        let closed = outcome == Ok(()) && exits_within(&mut child, Duration::from_secs(10));
        if !closed {
            let _ = child.kill();
        }
        let _ = std::fs::remove_file(&script);
        assert_eq!(outcome, Ok(()));
        assert!(closed, "the process quits once its window is closed");
    }

    #[test]
    fn describes_each_outcome_in_plain_words() {
        let key = ProcessKey { pid: 42, start_time: 1 };
        assert_eq!(describe("firefox", key, Ending::Ask, &Ok(())), "Asked firefox (PID 42) to quit.");
        assert_eq!(describe("firefox", key, Ending::Force, &Ok(())), "Ended firefox (PID 42) at once.");
        assert_eq!(
            confirmation("firefox", key),
            concat!(
                "Force quit firefox (PID 42)? It stops at once, and any unsaved work in it is lost. ",
                "End Task asks it to quit instead, so it can save first."
            )
        );
        assert_eq!(
            describe("firefox", key, Ending::Force, &Err(Refusal::Replaced)),
            "PID 42 now belongs to another process, so nothing was done."
        );
        assert!(describe("x", key, Ending::Ask, &Err(Refusal::NoWindow)).ends_with("Force Quit ends it."));
        assert!(describe("x", key, Ending::Ask, &Err(Refusal::NotPermitted)).contains("administrator rights"));
    }
}
