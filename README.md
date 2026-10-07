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
- Thermals: chip, SSD and battery temperatures over time, each fan's speed
  within its range, and every die sensor's lowest and highest reading since
  launch.

**History**: a flight recorder. Every 10 seconds the app writes CPU (average
and busiest moment), memory and pressure, GPU, power, disk, network, chip
temperature and the busiest apps to a small SQLite file, kept for 7 days.
Graphs cover the last hour, 6 hours, 24 hours or week; hovering over any of
them shows that moment's figures and which apps were using the most CPU and
memory then.

**Connections**: every TCP and UDP socket on the Mac, by process.
- Counts of open connections, listening ports, ports exposed to the network,
  remote hosts and processes with sockets, beside a live network traffic graph.
- A sortable table of process, PID, protocol, local and remote address, state
  (listening in green, established in blue) and scope: loopback, local network
  (private, link-local and unique-local addresses), internet, or all interfaces.
- Listeners on every interface (`0.0.0.0`, `::`) or a network address are
  flagged as reachable from other devices.
- Filters for established, listening, exposed and UDP sockets, and search by
  process, address or port.
- Details for each socket: both ends, the well-known service, what its scope
  means, and a jump to the owning process.
- It refreshes every 3 seconds, and only while the page is open. macOS only
  lists sockets for your own processes, so the page says how many root and
  other users' processes it can't see.

**Startup**: everything launchd starts by itself, read from the LaunchAgents
and LaunchDaemons folders. Each item shows whether it's yours, every user's or
a daemon, whether it's running (with its PID), loaded, disabled or not loaded,
what starts it (login or boot, a timer or schedule, a file change, or another
process asking for it), and whether Apple or a third party installed it.
Filter, sort and search, then check an item's full command line and triggers,
reveal its property list in Finder or open it. macOS keeps Login Items where
only an administrator can read them, so the page links to their pane in System
Settings instead.

**Users**: a card for each person using the Mac, with their processes added
up (CPU, memory, power, GPU), a minute of CPU and memory history, who's signed
in at the screen, their Terminal and remote logins, and their busiest
processes. Root and the service accounts sit together underneath, collapsed.

**System**: what this Mac is: model, chip and core types, memory, graphics,
displays, drives and volumes, network ports, battery health, macOS and kernel
versions, uptime, and whether SIP, FileVault and Gatekeeper are on. The serial
number, hardware UUID and MAC addresses stay hidden until you ask, and Copy
Summary puts the page on the clipboard as plain text.

**Everywhere else**
- A menu bar item with a live CPU bar graph and a popover of meters and top
  processes.
- ⌃⇧⎋ opens the window from anywhere, with no Accessibility permission needed.
- The `otm` command-line tool: `ps`, `top`, `system`, `power`, `sensors`,
  `ports`, `inspect` and `kill`, with JSON output.

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
telemetry, routing sockets for network counters, and each process's descriptor
table (`proc_pidfdinfo`) for its sockets. Startup items come from
the launchd property lists themselves, plus `launchctl list` and
`launchctl print` for what's loaded, running or disabled.

Power by part of the chip and clock speeds come from IOReport,
whole-system power and fan speeds from read-only SMC keys, and temperatures
from the HID event system's sensors. All three are undocumented, so
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
