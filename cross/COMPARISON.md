# Tauri, Slint and Qt: the same slice three ways

The same first slice of OpenTaskManager was built three times, to choose a
stack for Windows and Linux with evidence rather than opinion. Slint was
chosen; the other two prototypes live on in git history (commit `2a7f73f`,
branch `cross-compare`), and the paths below are from that commit:

- **Tauri** (`app/`): Rust core (`otm-core`) and a TypeScript interface in the
  system web view.
- **Slint** (`app-slint/`): the same Rust core, drawn natively by Slint.
- **Qt** (`app-qt/`): C++20 throughout. A plain C++ core reads Linux's `/proc`
  directly, and Qt 6 Widgets draws the interface.

Each has four live graphs (CPU, memory, disk, network), a sortable, searchable
process table (about 45–70 rows here), a tray icon drawing recent CPU load,
and close-to-tray. All three keep the Mac app's rules: "—" for a figure the
system didn't give, never zero; a process is its PID and start time;
processes are read only while the window shows. All three sample once a second.

## How they were measured

2026-10-24, WSL 2 on Windows 11 (Ubuntu 26.04, 16 logical CPUs). WSLg gives
no GPU here, so anything that asks for OpenGL gets Mesa's `llvmpipe`, which
renders on the CPU. Every app ran on X11 through WSLg's XWayland, with the
same libraries, release builds, 20 s to settle, then 60 s sampled once a
second over the app's whole process tree. CPU is in % of one core. Memory is
PSS (proportional set size: each process's private memory plus its share of
memory shared with others), summed over the tree.

| | Window open: CPU | Window open: memory | Window closed: CPU | Window closed: memory |
|---|---|---|---|---|
| Tauri (WebKitGTK, graphs stepping), GTK tray | 9.0% | 455 MB | 0.30% | 46 MB |
| Slint, GPU renderer (here `llvmpipe`), GTK tray | 6.4% | 149 MB | 0.32% | 30 MB |
| Slint, CPU renderer (`SLINT_BACKEND=winit-software`), GTK tray | 1.0% | 37 MB | 0.32% | 30 MB |
| **Slint, CPU renderer, no tray** (`--no-tray`) | **0.75%** | **21 MB** | **0.07%** | **13 MB** |
| **Qt Widgets, no tray** (none found) | **0.83%** | **31 MB** | **0.03%** | **20 MB** |

Tray fairness: WSLg has no tray host. Tauri and Slint still create their
tray through `tray-icon`, which on Linux loads GTK and AppIndicator and
redraws the icon through a file each second. Qt finds no tray and creates
none. The two bold rows are like for like. The GTK tray stack alone costs
about 16 MB and 0.25% of a core, as much as the rest of the Slint app. A
D-Bus tray without GTK (the `ksni` crate, the StatusNotifierItem protocol)
would avoid it on Linux.

## What else differed

| | Tauri | Slint | Qt |
|---|---|---|---|
| Release binary | 4.8 MB, plus the system's WebKitGTK (121 MB of libraries) | 15.3 MB, self-contained | 0.2 MB, plus Qt's libraries (65 MB, before plugins) |
| Clean release build | about 100 s | about 110 s | about 11 s, given a Qt SDK |
| Code (non-blank, non-comment) | 174 Rust + 923 TS/CSS/HTML, on the 756-line core | 512 Rust + 197 Slint, on the same core | 522 C++ core + 612 Qt UI + 96 tests |
| Checks | 19 Rust tests (`otm-core`), clippy `-D warnings`, strict TypeScript 7 | 31 Rust tests, clippy `-D warnings` | 7 QtTest cases, `-Wall -Wextra -Wpedantic -Wshadow -Werror` |
| Memory safety | Yes (Rust) | Yes (Rust) | No (C++) |
| Windows build | Not yet (needs C++ Build Tools) | Not yet (same) | Not yet (needs Qt for MSVC) |

## What building them showed

- **Tauri** was the quickest interface to build, with the most freedom in
  how it looks, but the web view is the bill. It costs about 450 MB with the
  window open, and here 9% of a core even with stepping graphs. On Linux,
  WebKit hides the GPU's name, so graphs can't safely slide. Tauri's earlier
  measurement with sliding graphs was 181–194%.
- **Slint** reused the Rust core unchanged and needed the most care in
  layout. A path keeps its aspect ratio, so the graphs are drawn in pixels
  the window reports. Its standard table can't right-align figures, and
  callbacks re-enter, so the view guards against that. The Linux tray needs
  a GTK thread of its own. Its GPU renderer is the costly part here: with
  no GPU, OpenGL falls back to `llvmpipe` (149 MB). The CPU renderer
  drew the same window for 1% and 37 MB, and Slint can choose it at run time.
- **Qt** had the most finished table with the least effort: right-aligned
  figures, a sort indicator, and selection and scroll position kept across
  updates. It built fastest, and its warnings were clean on the first try.
  The costs: the `/proc` sampler that `sysinfo` gave Rust for free had to be
  written (about 520 lines, Linux only so far), C++ offers no memory safety
  for that parsing, and the app ships with Qt's libraries.

## Conclusion

**Rust with Slint**, using its CPU renderer by default and a non-GTK tray on Linux.

- It matches Qt's footprint: 21 MB against 31 MB with the window open, and
  13 MB against 20 MB closed, at the same fraction of a percent of CPU.
  That's about a twentieth of Tauri's memory.
- It keeps memory safety and the Rust core (`otm-core`, with its tests)
  that Tauri already proved.
- Its rough edges are real but small (table alignment, path scaling,
  re-entrant callbacks), and each now has a known answer in `app-slint/`.

Qt is a close and credible second. It has the best ready-made table and
the quickest build. But it means C++ for the risky
parsing and process work, a second copy of the core, and shipping Qt.
Tauri is out for a task manager: the web view costs about 450 MB with the
window open, and it's the only one of the three that can't tell whether a
GPU will draw its animations.

Not yet known, and worth checking before committing:

- Windows builds of Tauri and Qt. The Slint app has since been built,
  tested and measured on Windows: 1.18% of a core and 11.8 MB of private
  memory with the window open (see README.md).
- A Linux desktop with a real GPU, where Slint's GPU renderer and WebKit
  should both cost less.
- A machine with hundreds of processes.
