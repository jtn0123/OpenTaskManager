//! One running copy per account and session: a second launch hands its
//! request (open the window, or quit) to the copy already running, then
//! exits. Linux uses an abstract socket whose peers must be this account;
//! Windows uses a session-local mutex and two events.

use std::io;

/// The usual instance; tests run under their own names, with their own
/// settings and sign-in entry, so they never touch this one.
pub const DEFAULT: &str = "default";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Message {
    Open,
    Quit,
}

/// The outcome of starting up.
pub enum Claim {
    /// No other copy runs; this one now answers to the name.
    First(Listener),
    /// Another copy of this account's runs under the name.
    Running,
}

/// Whether `name` can name an instance: letters, digits, '-' and '_'.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
}

/// Claims `name` for this process, unless another copy holds it.
pub fn claim(name: &str) -> io::Result<Claim> {
    platform::claim(name)
}

/// Hands `message` to the copy running under `name`.
pub fn send(name: &str, message: Message) -> io::Result<()> {
    platform::send(name, message)
}

#[cfg(target_os = "linux")]
mod platform {
    use std::io::{self, Read, Write};
    use std::os::linux::net::SocketAddrExt;
    use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};
    use std::thread;
    use std::time::Duration;

    use rustix::net::sockopt::socket_peercred;
    use rustix::process::getuid;

    use super::{Claim, Message};

    pub struct Listener(UnixListener);

    /// Abstract sockets have no file permissions, so the name carries the
    /// account and both ends check the other's.
    fn address(name: &str) -> io::Result<SocketAddr> {
        SocketAddr::from_abstract_name(format!("opentaskmanager-{}-{name}", getuid().as_raw()))
    }

    fn same_account(stream: &UnixStream) -> bool {
        socket_peercred(stream).is_ok_and(|peer| peer.uid == getuid())
    }

    pub fn claim(name: &str) -> io::Result<Claim> {
        match UnixListener::bind_addr(&address(name)?) {
            Ok(listener) => Ok(Claim::First(Listener(listener))),
            Err(error) if error.kind() == io::ErrorKind::AddrInUse => Ok(Claim::Running),
            Err(error) => Err(error),
        }
    }

    pub fn send(name: &str, message: Message) -> io::Result<()> {
        let mut stream = UnixStream::connect_addr(&address(name)?)?;
        if !same_account(&stream) {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "another account holds the name"));
        }
        stream.write_all(match message {
            Message::Open => b"open\n",
            Message::Quit => b"quit\n",
        })
    }

    impl Listener {
        /// Answers requests on a thread of its own for as long as the process runs.
        pub fn serve(self, on_message: impl Fn(Message) + Send + 'static) {
            let spawned = thread::Builder::new().name("instance".into()).spawn(move || {
                for stream in self.0.incoming() {
                    let Ok(stream) = stream else { continue };
                    if !same_account(&stream) {
                        continue;
                    }
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut text = String::new();
                    if stream.take(16).read_to_string(&mut text).is_err() {
                        continue;
                    }
                    match text.trim() {
                        "open" => on_message(Message::Open),
                        "quit" => on_message(Message::Quit),
                        _ => {}
                    }
                }
            });
            if let Err(error) = spawned {
                eprintln!("Couldn't listen for other launches: {error}");
            }
        }
    }
}

#[cfg(windows)]
mod platform {
    use std::io;
    use std::thread;
    use std::time::{Duration, Instant};

    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Threading::{
        CreateEventW, CreateMutexW, EVENT_MODIFY_STATE, INFINITE, OpenEventW, SetEvent, WaitForMultipleObjects,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{ASFW_ANY, AllowSetForegroundWindow};

    use super::{Claim, Message};

    /// A handle closed when dropped.
    struct Owned(HANDLE);

    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: the handle came from a Create or Open call and is closed only here, once.
            unsafe { CloseHandle(self.0) };
        }
    }

    // SAFETY: kernel handles may be used and closed from any thread.
    unsafe impl Send for Owned {}

    pub struct Listener {
        /// Held for the process's life: its existence is the claim.
        _mutex: Owned,
        open: Owned,
        quit: Owned,
    }

    /// Kernel object names under Local\ belong to this sign-in session.
    fn object(name: &str, what: &str) -> Vec<u16> {
        format!("Local\\OpenTaskManager-{name}-{what}").encode_utf16().chain([0]).collect()
    }

    fn event(name: &str, what: &str) -> io::Result<Owned> {
        let name = object(name, what);
        // SAFETY: an auto-reset, unsignalled event; `name` is NUL-terminated and outlives the call.
        let handle = unsafe { CreateEventW(std::ptr::null(), 0, 0, name.as_ptr()) };
        if handle.is_null() { Err(io::Error::last_os_error()) } else { Ok(Owned(handle)) }
    }

    pub fn claim(name: &str) -> io::Result<Claim> {
        // The events come first, so a second launch that finds the mutex finds them too.
        let open = event(name, "open")?;
        let quit = event(name, "quit")?;
        let mutex = object(name, "instance");
        // SAFETY: an unowned mutex; `mutex` is NUL-terminated and outlives the call.
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, mutex.as_ptr()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: reads this thread's last error, set by CreateMutexW just above.
        let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        let mutex = Owned(handle);
        if existed {
            return Ok(Claim::Running);
        }
        Ok(Claim::First(Listener { _mutex: mutex, open, quit }))
    }

    pub fn send(name: &str, message: Message) -> io::Result<()> {
        let event = object(name, if message == Message::Open { "open" } else { "quit" });
        // The running copy may be a moment from creating its events.
        let started = Instant::now();
        loop {
            // SAFETY: `event` is NUL-terminated and outlives the call; a null handle is checked.
            let handle = unsafe { OpenEventW(EVENT_MODIFY_STATE, 0, event.as_ptr()) };
            if !handle.is_null() {
                let event = Owned(handle);
                if message == Message::Open {
                    // Let the running copy bring its window to the front, as this launch was the user's.
                    // SAFETY: takes no pointers.
                    unsafe { AllowSetForegroundWindow(ASFW_ANY) };
                }
                // SAFETY: the handle is open with modify rights.
                return if unsafe { SetEvent(event.0) } == 0 { Err(io::Error::last_os_error()) } else { Ok(()) };
            }
            if started.elapsed() > Duration::from_secs(2) {
                return Err(io::Error::last_os_error());
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    impl Listener {
        /// Answers requests on a thread of its own for as long as the process runs.
        pub fn serve(self, on_message: impl Fn(Message) + Send + 'static) {
            let Listener { _mutex: mutex, open, quit } = self;
            let spawned = thread::Builder::new().name("instance".into()).spawn(move || {
                // Moved in whole, so the handles stay open for as long as this thread waits on them.
                let (_mutex, open, quit) = (mutex, open, quit);
                let events = [open.0, quit.0];
                loop {
                    // SAFETY: both handles stay open for this thread's life (it owns them).
                    let signalled = unsafe { WaitForMultipleObjects(2, events.as_ptr(), 0, INFINITE) };
                    match signalled.wrapping_sub(WAIT_OBJECT_0) {
                        0 => on_message(Message::Open),
                        1 => on_message(Message::Quit),
                        _ => return,
                    }
                }
            });
            if let Err(error) = spawned {
                eprintln!("Couldn't listen for other launches: {error}");
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use std::io;

    use super::{Claim, Message};

    pub struct Listener;

    pub fn claim(_name: &str) -> io::Result<Claim> {
        Ok(Claim::First(Listener))
    }

    pub fn send(_name: &str, _message: Message) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no other copy to reach"))
    }

    impl Listener {
        pub fn serve(self, _on_message: impl Fn(Message) + Send + 'static) {}
    }
}

pub use platform::Listener;

#[cfg(all(test, any(target_os = "linux", windows)))]
mod tests {
    use std::sync::mpsc;
    use std::time::Duration;

    use super::{Claim, Message, claim, send, valid_name};

    #[test]
    fn a_second_claim_finds_the_first_and_reaches_it() {
        let name = format!("test-{}", std::process::id());
        let Claim::First(listener) = claim(&name).expect("claimed") else { panic!("nothing else holds the name") };
        assert!(matches!(claim(&name).expect("checked"), Claim::Running));
        let (tell, heard) = mpsc::channel();
        listener.serve(move |message| tell.send(message).expect("the test listens"));
        send(&name, Message::Open).expect("sent");
        assert_eq!(heard.recv_timeout(Duration::from_secs(5)), Ok(Message::Open));
        send(&name, Message::Quit).expect("sent");
        assert_eq!(heard.recv_timeout(Duration::from_secs(5)), Ok(Message::Quit));
    }

    #[test]
    fn names_are_plain() {
        assert!(valid_name("default"));
        assert!(valid_name("smoke-1234_a"));
        assert!(!valid_name(""));
        assert!(!valid_name("../x"));
        assert!(!valid_name("a b"));
        assert!(!valid_name(&"x".repeat(65)));
    }
}
