# OpenTaskManager for Windows and Linux

The start of a cross-platform OpenTaskManager, built with
[Tauri 2](https://tauri.app): a Rust core that reads the system, and a
TypeScript interface in the system's own web view (WebView2 on Windows,
WebKitGTK on Linux). The Mac app in `App/` and `Packages/` stays native Swift;
this folder doesn't touch it.

It's an early slice, not a release: live CPU, memory, disk and network
graphs, a sortable, searchable process table, and a tray icon with a live CPU
graph. It exists to prove the stack and measure its cost before more is
built on it.

The same slice is also built with **Slint** (`app-slint/`, on the same Rust
core) and with **C++ and Qt 6** (`app-qt/`, its own `/proc` sampler), to
choose between the three by measurement. See [COMPARISON.md](COMPARISON.md):
Slint and Qt use about 20–30 MB with the window open, against Tauri's 455 MB,
and the comparison recommends Slint.

```sh
cargo run --release -p opentaskmanager-slint      # Slint; --hidden, --no-tray
SLINT_BACKEND=winit-software cargo run --release -p opentaskmanager-slint
cmake -S app-qt -B app-qt/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt 6 dir>
cmake --build app-qt/build && ctest --test-dir app-qt/build
```

## Rules carried over from the Mac app

- **A figure the system didn't give is "—", never zero.** In Rust it's an
  `Option`; the generated TypeScript types make it `| null`, so the interface
  can't forget it. A process seen for the first time has no CPU or disk rate
  yet; another account's disk I/O is private on Linux without root.
- **A process is its PID and start time** (`ProcessKey`), so a reused PID never
  inherits another process's selection.
- **Stay light.** Sampling happens once a second in Rust. Processes are read
  only while the window is on screen. Closing the window destroys its web
  view; the tray keeps sampling the totals in one small process. Graphs are
  drawn once per sample and slid by the compositor in between, only where a
  GPU is confirmed: a software renderer steps them instead (see below).
- **Pure rules live in `otm-core`, with tests**: sampling and priming, the
  rate axes, the history ring, the tray icon's pixels.

## Layout

```
crates/otm-core/      Sampling (sysinfo), the figures' types, axis scaling, tray icon pixels
app/src-tauri/        The app: tray, window, sampler thread, one `history` command and a `tick` event
app/src/              The interface: graphs, process table, formatting
app/src/bindings/     TypeScript types generated from otm-core by `cargo test` (ts-rs): don't edit
```

## Build

You need Rust 1.90 or later and Node.js 20 or later, plus:

- **Linux**: WebKitGTK 4.1, GTK 3, ayatana-appindicator, librsvg and the usual
  build tools. On Debian or Ubuntu: `sudo apt install build-essential
  pkg-config libssl-dev libwebkit2gtk-4.1-dev libgtk-3-dev
  libayatana-appindicator3-dev librsvg2-dev libxdo-dev`.
- **Windows**: Microsoft C++ Build Tools (Desktop development with C++) and
  the WebView2 runtime, which Windows 11 already has.

```sh
cargo test --workspace                                  # also regenerates app/src/bindings
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
cd app
npm ci
npm run check                                           # strict TypeScript
npx tauri dev                                           # run with live reload
npx tauri build                                         # release build and installers
npx tauri build --no-bundle                             # just the binary
```

`--hidden` starts with the tray only. In a plain browser, `npm run dev` shows
the interface with made-up figures and a Preview badge, for layout work.

## Status

Measured 2026-10-24 in WSL 2 (Ubuntu 26.04, 16 logical CPUs, about 70
processes; WebKit's compositor fell back to software rendering, `llvmpipe`),
release build, 20 s to settle then 60 s, whole process tree (app, WebKit's
web and network processes):

| State | CPU, % of one core | Memory (PSS) |
|---|---|---|
| Window open, graphs sliding (`--slide-graphs`) | 181–194% | ~470 MB |
| Window open, graphs stepping (the default here) | 10.0% (web view 9.1%, app 0.8%) | ~470 MB |
| Window closed, tray only (`--hidden`) | 0.3% | 46 MB |

What that shows:

- Sliding graphs are only affordable where a GPU composites. Only Chromium's
  web view (WebView2) names the GPU; WebKit calls every renderer "Apple GPU",
  so on Linux graphs step unless `--slide-graphs` is given. The status bar
  says when they step and why.
- The web view's memory is the real cost: about 470 MB with the window open
  here (software rendering inflates it; real GPUs should be lower), against
  46 MB with it closed. Closing the window to the tray gives that back.
- Not measured yet: Windows (WebView2), a Linux desktop with a real GPU,
  hundreds of processes.

Known gaps: no process actions yet (End Task and the rest), no history
recording, no per-OS readers beyond what `sysinfo` provides (GPU, sensors,
per-process network), and the Linux tray logs a GTK warning on each icon
update (`gtk_widget_get_scale_factor`, from the tray library). Windows hasn't
been built yet: it needs the C++ Build Tools.
