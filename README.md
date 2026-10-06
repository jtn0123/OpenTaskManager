# OpenTaskManager

A fast, native, open-source task manager for macOS: the Windows Task Manager
layout people already know, rebuilt for Apple silicon and taken further.

> Status: pre-release (0.1 in progress). Builds and runs on macOS 14 or later.

## What it does today

**Overview**: one screen with a glowing gauge for CPU, memory, GPU and power,
a live map of every core grouped by type (for example 6 Super + 12 Performance
on an M5 Pro), disk, network, power by part of the chip, storage, and the apps
using the most CPU, memory and energy right now. Numbers count smoothly to each
new reading.

**Processes**
- Apps, background processes and system processes, with helpers folded under
  the app that owns them (Safari's web content processes sit under Safari).
  There are also parent/child tree and flat views.
- Columns: CPU, memory, **power in watts**, **GPU**, disk, threads, fast-core
  share, wakeups, user and kind (Apple silicon or Rosetta). Busy values get
  meter bars, and the headers show live system totals.
- CPU is shown as a share of the whole machine, so it never exceeds 100%.
  Activity Monitor's 100%-per-core scale is a setting.
- End Task (quits apps politely), Force Quit, End Process Tree, Suspend and
  Resume, any signal, priority (nice), Sample Process, Reveal in Finder.
  Actions on system processes ask for an administrator password only when
  they're needed.
- An inspector with per-process CPU, memory, power and GPU graphs, command
  line, environment, working directory, and open files and network ports.

**Performance**: Task Manager-style graphs that scroll smoothly between
samples and scale their axes to round numbers.
- CPU: overall, by core type or every core, the clock speed of each cluster,
  and a stacked chart of CPU by app.
- Memory: what's in memory over time (wired, app, compressed, cached), pressure,
  swap, paging and compressor activity, and memory by app.
- GPU: shading and geometry load, GPU time by app, clock speed and GPU memory.
- Power: where the power goes (CPU, GPU, Neural Engine, DRAM and the rest of
  the system), energy since launch, adapter and battery flow, and power by app.
- Each disk and network interface.

**Everywhere else**
- A menu bar item with a live CPU bar graph and a popover of meters and top
  processes.
- ⌃⇧⎋ opens the window from anywhere, with no Accessibility permission needed.
- The `otm` command-line tool: `ps`, `top`, `system`, `power`, `ports`,
  `inspect` and `kill`, with JSON output.

OpenTaskManager is light. Graphs, gauges and core tiles animate in Core
Animation's render server, and the process table moves rows in place instead
of rebuilding them, so the app itself uses only a few percent of one core.

## Build

You need Xcode 16 or later (the full app, not just the Command Line Tools) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run          # generate the Xcode project, build, and launch
make test         # run the OTMKit test suite
make cli          # build the otm tool; `make install-cli` copies it to /usr/local/bin
make release      # optimized build in .build/xcode/Build/Products/Release
```

The Makefile finds Xcode by itself even when `xcode-select` points at the
Command Line Tools. The Xcode project is generated from `project.yml` and isn't
checked in.

Builds are ad-hoc signed, so they run on the machine that built them. Signed
and notarized downloads need an Apple Developer account; they're on the
[roadmap](ROADMAP.md).

## How it reads the system

Root isn't needed. Most figures come from public kernel and IOKit
interfaces: `libproc` and `proc_pid_rusage` for processes and energy,
`host_processor_info` for each core, `host_statistics64` for memory (using the
same arithmetic as Activity Monitor), IOKit for the GPU, disks and battery
telemetry, and routing sockets for network counters.

Power by part of the chip and clock speeds come from IOReport, and
whole-system power from read-only SMC keys. Both are undocumented, so
OpenTaskManager loads them at run time and shows "—" for anything a Mac
doesn't report.

macOS hides most details of other users' processes from unprivileged apps. For
those, OpenTaskManager falls back to `/bin/ps` for CPU and memory and marks the
rest as unavailable. An optional privileged helper that lifts this limit is
planned.

## Layout

```
App/                 SwiftUI + AppKit app (views, model, menu bar, settings)
Packages/OTMKit/     Sampling library, the otm CLI, and tests
scripts/             Icon renderer and other tooling
project.yml          XcodeGen project definition
```

## Relationship to other task managers

OpenTaskManager is an independent, clean-room project. It isn't affiliated with
Microsoft, with Apple, or with "Task Manager OG" for Mac, and it contains no
code, artwork or other assets from any of them. The layout follows the familiar
Windows Task Manager conventions; everything here was written from scratch.

## License

[GPL-3.0](LICENSE).
