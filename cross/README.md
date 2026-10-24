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
- A tray icon drawing recent CPU load, with close-to-tray.

## Rules carried over from the Mac app

- **A figure the system didn't give is "—", never zero.** In Rust it's an
  `Option`. A process seen for the first time has no CPU or disk rate yet;
  another account's disk I/O is private on Linux without root.
- **A process is its PID and start time** (`ProcessKey`), so a reused PID never
  inherits another process's selection.
- **Stay light.** Sampling happens once a second on its own thread. Processes
  are read only while the window is on screen. Closing the window drops it
  and its renderer; the tray keeps sampling the totals. Graphs are redrawn
  once per sample, not per frame.
- **Pure rules live in `otm-core`, with tests**: sampling and priming,
  formatting, the table's search and order, rate axes, the tray icon's
  pixels. `app/src/graph.rs` (graph paths) is tested too.

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
crates/otm-core/   Sampling (sysinfo), figures, formatting, table rules, axis scaling, tray icon pixels
app/ui/app.slint   The window: graph cards, process table, status line
app/src/main.rs    The view: sampler thread, window life, table model, callbacks
app/src/graph.rs   Graph lines as path commands in the graph's own pixels
app/src/tray.rs    The tray: ksni on Linux, tray-icon elsewhere
```

## Build

You need Rust 1.90 or later, plus:

- **Linux**: a C toolchain, `pkg-config`, and the X11 and Wayland client
  libraries most desktops already have (`libxkbcommon-x11`, `libwayland`,
  `libfontconfig`). A D-Bus session bus for the tray.
- **Windows**: Microsoft C++ Build Tools (Desktop development with C++).

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
cargo run --release -p opentaskmanager            # --hidden: tray only; --no-tray: none
```

## Status

Measured 2026-10-24 in WSL 2 (Ubuntu 26.04, 16 logical CPUs, no GPU, about
50 processes), release build, 20 s to settle, then 60 s sampled:

| State | CPU, % of one core | Memory (PSS) |
|---|---|---|
| Window open | 0.65% | 19 MB |
| Window closed | 0.08% | 12 MB |

For comparison, the Tauri prototype took 9% and 455 MB with its window open,
and the C++/Qt one 0.83% and 31 MB (see COMPARISON.md).

What isn't verified yet:

- WSLg has no tray host, so the tray didn't start in those runs; the D-Bus
  tray hasn't been seen working on a real desktop.
- The window was checked by screenshot. Sorting by clicking a header,
  keyboard selection and the tray menu haven't been driven by an automated
  test.

Known gaps: no process actions yet (End Task and the rest), no history
recording, no per-OS readers beyond what `sysinfo` provides (GPU, sensors,
per-process network). Windows type-checks with Clippy, but hasn't been built
or run there yet.
