# OpenTaskManager for Windows and Linux

The start of a cross-platform OpenTaskManager: a Rust core that reads the
system (`crates/otm-core`, on `sysinfo`) and a native interface drawn with
[Slint](https://slint.dev) (`app/`). The Mac app in `App/` and `Packages/`
stays native Swift; this folder doesn't touch it.

Slint was chosen by building the same slice three ways (Tauri, Slint, C++/Qt)
and measuring them; see [COMPARISON.md](COMPARISON.md). The Tauri and Qt
prototypes are in git history: the Tauri app is commit `006ee58` (branch
`cross-tauri`), and all three together are commit `2a7f73f` (branch
`cross-compare`).

It's an early slice, not a release:

- Live CPU, memory, disk and network graphs.
- A process table: search, sorting by any column, right-aligned figures, and
  a selection that follows its process through re-sorts (Up and Down move it).
- Processes grouped by app (or one flat list): a header sums each group's
  figures and opens to its members (its triangle, or Right and Left). While
  searching, groups open to show which members matched.
- A details panel for the selection: program file, command line, what
  started it, how long it has run, its account and its group.
- End Task and Force Quit for the selected process, or a whole group from
  its header (Delete and Shift+Delete). Force Quit asks first, naming the
  process and PID, or the group and how many; the outcome stays above the
  table until dismissed (Esc).
- A tray icon drawing recent CPU load, with close-to-tray.
- One running copy: launching it again brings its window to the front.
- It remembers the window's size, the sort and the update speed (every 1, 2
  or 5 s), and can start at sign-in, hidden in the tray.

## Rules carried over from the Mac app

- **A figure the system didn't give is "—", never zero.** In Rust it's an
  `Option`. A process seen for the first time has no CPU or disk rate yet;
  another account's disk I/O is private on Linux without root.
- **A process is its PID and start time** (`ProcessKey`), so a reused PID never
  inherits another process's selection, or its End Task. Ending one
  (`otm_core::actions`) first takes a kernel handle to the PID (a pidfd on
  Linux, a process handle on Windows), then checks the start time through
  it and signals through it, so a PID reused in between can't be hit.
  Force Quit's target is fixed when its question opens.
- **Stay light.** Sampling happens once a second on its own thread. Processes
  are read only while the window is on screen. Closing the window drops it
  and its renderer; the tray keeps sampling the totals. Graphs are redrawn
  once per sample, not per frame.
- **Pure rules live in `otm-core`, with tests**: sampling and priming,
  formatting, the table's search and order, rate axes, the tray icon's
  pixels. `app/src/graph.rs` (graph paths) is tested too.

## Groups

A process sits under the process that started it, unless that one is a
launcher: Explorer, the service manager, svchost and the session's own
processes on Windows; init, systemd, the session and display managers and
the desktop shell on Linux (`otm_core::groups`). Those start apps without
being part of them, so each app they start heads its own group, and a
browser's helpers or a terminal's shells sit with it. A parent only counts
if it started no later than the process naming it, so a reused PID never
collects an ended app's helpers. A header's figures are its members' sums;
one that no member reported stays "—".

A selected member whose group is closed moves the selection to its header;
a selected process that ends clears it, so End Task (which doesn't ask
first) never lands on a group nobody picked.

## Ending a process

| | End Task | Force Quit |
|---|---|---|
| Linux | SIGTERM, so it can save and quit | SIGKILL |
| Windows | Closes its visible windows, as their close buttons would | `TerminateProcess` |

Nothing is done, and the notice says why, when the process has already
ended, its PID now belongs to a process started at another time, it's
another account's or protected (ending it needs administrator rights), it's
OpenTaskManager itself, or (End Task on Windows) it has no window to close,
when Force Quit is the way. The wording of the question is the Mac app's.

A group is ended one member at a time, each checked as above just before:
Force Quit from the bottom up, so no parent outlives its children long
enough to start more; End Task from the top, so an app can close its own
helpers. The targets are fixed when Force Quit's question opens, and the
notice counts what was ended and why the rest weren't.

## Choices that keep it light

- **The CPU renderer is the default** (`BackendSelector`, `winit` +
  `software`). The window redraws a few small regions a second, and in
  measurement the GPU renderer cost far more when no GPU was available.
  Set `SLINT_BACKEND` (for example `winit-femtovg`) to choose another.
- **The Linux tray is a StatusNotifierItem over D-Bus** (`ksni`), so no GTK is
  loaded; GTK alone cost about 16 MB in measurement. Windows and macOS use
  their own tray through `tray-icon`. Desktops without a tray host (GNOME
  without its extension, WSLg) get no icon, and the app says so on stderr.
- **The table is its own component**: only the rows in view exist
  (`ListView`), and rows change in place, so the scroll position holds.

## Layout

```
crates/otm-core/   Sampling (sysinfo), figures, formatting, table rules, axis scaling, tray icon pixels,
                   ending a process (actions.rs: rustix on Linux, windows-sys on Windows),
                   settings, one running copy (instance.rs) and start at sign-in (autostart.rs),
                   grouping by app (groups.rs) and a process's details (details.rs)
app/ui/app.slint   The window: graph cards, End Task and Force Quit, process table, status bar
app/src/main.rs    The view: sampler thread, window life, graphs, settings, callbacks
app/src/table.rs   The table's rows, selection, details panel and ending what's selected
app/src/graph.rs   Graph lines as path commands in the graph's own pixels
app/src/tray.rs    The tray: ksni on Linux, tray-icon elsewhere
```

## Build

You need Rust 1.90 or later, plus:

- **Linux**: a C toolchain, `pkg-config`, and the X11 and Wayland client
  libraries most desktops already have (`libxkbcommon-x11`, `libwayland`,
  `libfontconfig`). A D-Bus session bus for the tray.
- **Windows**: Microsoft C++ Build Tools (Desktop development with C++), or
  no Windows toolchain at all: cross-compile from Linux or WSL as below.

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
cargo run --release -p opentaskmanager   # --hidden: tray only; --no-tray: none; --exit-after N: quit after N s
```

Another launch hands over to the copy already running and exits: it opens
that copy's window, or with `--quit` asks it to quit. `--instance NAME`
runs a separate copy with its own settings file and sign-in entry; the
smoke test uses one so the user's are never touched.

Settings are a short `key = value` file: `%APPDATA%\OpenTaskManager\settings.conf`
on Windows, `~/.config/opentaskmanager/settings.conf` on Linux. Start at
sign-in writes a value in the account's Run key on Windows (and clears any
"disabled" mark Task Manager left for it), or
`~/.config/autostart/opentaskmanager.desktop` on Linux; neither needs
administrator rights. On Windows one copy per sign-in session is a
session-local mutex and two events; on Linux an abstract socket, whose
both ends check the other is the same account.

Without admin rights or Visual Studio, the Windows build can be made from
Linux or WSL with Microsoft's libraries fetched by `xwin` (it asks you to
accept Microsoft's licence) and Rust's own linker:

```sh
rustup target add x86_64-pc-windows-msvc
cargo install xwin --locked
xwin --accept-license --arch x86_64 --cache-dir ~/opt/xwin-cache splat --output ~/opt/xwin
export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=rust-lld
export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS="-Lnative=$HOME/opt/xwin/crt/lib/x86_64 -Lnative=$HOME/opt/xwin/sdk/lib/um/x86_64 -Lnative=$HOME/opt/xwin/sdk/lib/ucrt/x86_64"
cargo build --release --target x86_64-pc-windows-msvc -p opentaskmanager
```

`scripts/smoke-windows.ps1` then drives the Windows build through UI
Automation, the accessibility tree Slint exposes, so it never moves the
mouse or takes the keyboard. It clicks headers and checks the rows' order,
searches, and checks that a protected process shows "—", not 0 bytes. Then it
starts a ping with no window, selects it, and checks that End Task says
Force Quit is needed, that Force Quit asks first and Cancel ends nothing,
and that confirming ends it (it kills the ping itself if a check fails).
Then it opens a group header, starts a cmd.exe running ping through a cmd
that exits (so the group stands alone and can't take in the test), checks
the details panel names what started the ping, and ends the group: End
Task says Force Quit is needed, Force Quit asks with how many, and
confirming ends both. It turns Group by app off and on.
Last, it checks that a second launch hands over and exits, that Start at
sign-in writes and removes its Run value, and that the sort and a resized
window survive `--quit` and a relaunch. It runs as its own instance and
removes that instance's settings and Run value at the end:
`powershell -ExecutionPolicy Bypass -File scripts\smoke-windows.ps1 -Exe <path to opentaskmanager.exe>`.

## Status

Measured 2026-10-24, release builds, 20 s to settle, then 60 s sampled.

Windows 11, natively (16 logical CPUs, about 290 processes):

| State | CPU, % of one core | Private working set | Working set |
|---|---|---|---|
| Window open | 1.18% | 11.8 MB | 27.5 MB |
| Window closed | 0.02% | 5.1 MB | 15.6 MB |

In the app's own table on that machine, Windows' Task Manager showed a
working set of 123 MB against the app's 37 MB (same measure, same reader).

Linux, in WSL 2 (Ubuntu 26.04, 16 logical CPUs, no GPU, about 50 processes):

| State | CPU, % of one core | Memory (PSS) |
|---|---|---|
| Window open | 0.65% | 19 MB |
| Window closed | 0.08% | 12 MB |

For comparison, the Tauri prototype took 9% and 455 MB with its window open,
and the C++/Qt one 0.83% and 31 MB (see COMPARISON.md).

Verified on Windows: the core's 48 tests run natively, including one that
no process Windows won't open shows 0 bytes, and End Task and Force Quit on
real processes: one closed through an invisible window that never takes
focus, a PID with the wrong start time refused and left running, and the
System process refused, registry writes under a test key, and a group of
two processes ended in order. All 47 smoke checks pass. Windows registered the tray icon. On Linux (WSL) the core's 47 tests pass, including SIGTERM and
SIGKILL on real processes and PID 1 refused to an ordinary account.

Not verified yet:

- The Linux tray: WSLg has no tray host, so it didn't start there.
- Keyboard selection, Delete and Shift+Delete, Right and Left on groups,
  clicking a header's triangle, and the tray menu: no test drives them (UI
  Automation invokes the buttons and opens groups instead).
- The Linux window's End Task and Force Quit buttons: the Linux actions are
  tested in the core, the buttons only on Windows.
- The update speed menu: UI Automation can't pick from Slint's drop-down,
  so only the settings rules behind it are tested.
- A real sign-in: the Run value and the Linux autostart entry are checked as
  written, not by signing in again.

Known gaps: no multiple selection, no history
recording, no per-OS readers beyond what `sysinfo` provides (GPU, sensors,
per-process network). macOS hasn't been built; the Swift app covers it.
