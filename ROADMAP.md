# Roadmap

The aim is everything a Windows-style task manager on the Mac should do, then a
good deal more. ✅ done · 🚧 in progress · ⬜ planned

## Task Manager parity

| Area | Status | Notes |
| --- | --- | --- |
| Processes grouped as Apps / Background / System | ✅ | Grouped by macOS "responsible process", so helpers sit under their app |
| Tree and flat views | ✅ | |
| Collapsed groups show totals | ✅ | |
| End task, end process tree, force quit | ✅ | Apps quit politely first |
| Column chooser, sorting, saved column layout | ✅ | Right-click the header |
| Heat shading of busy values | ✅ | Meter bars, coloured per resource |
| Performance: CPU, memory, disk, network, GPU graphs | ✅ | Plus power and battery. Graphs scroll smoothly and auto-scale |
| Per-core CPU graphs | ✅ | Grouped by core type |
| Status bar summary | ✅ | |
| Always-available shortcut (⌃⇧⎋) | ✅ | |
| App history (resource use per app over days) | ⬜ | Needs the history database below |
| Startup apps | 🚧 | LaunchAgents and LaunchDaemons with status, PID, triggers and publisher are done. Login Items and the background items apps register need root to read, so they wait for the privileged helper; for now the page opens their System Settings pane |
| Enable and disable startup items | ⬜ | TODO: `launchctl enable`/`disable` with `bootstrap`/`bootout`, a confirmation step and a way to undo. Daemons need an administrator password. Left out until then because it's destructive |
| Users tab | ⬜ | Per-user totals, log off other sessions |
| Services tab | ⬜ | launchd services: state, start/stop, open plist. The Startup page already reads each job's state and opens its plist |
| "Details" tab extras: priority, affinity-style tier pinning | 🚧 | Priority is done; QoS and tier pinning are planned |
| Search, efficiency mode equivalent | 🚧 | Search is done; "efficiency mode" maps to background QoS |

## Beyond Task Manager

| Feature | Status | Notes |
| --- | --- | --- |
| Per-process power in watts | ✅ | From `ri_energy_nj` |
| Per-process GPU % | ✅ | From the AGX user clients |
| Fast-core share and wakeups per process | ✅ | |
| Inspector: arguments, environment, open files, sockets | ✅ | |
| Sample Process (stack sampling) | ✅ | Uses `/usr/bin/sample` |
| Menu bar meters and top processes | ✅ | |
| `otm` CLI with JSON output | ✅ | `ps`, `top`, `system`, `power`, `ports`, `inspect`, `kill` |
| Overview dashboard with live core map | ✅ | |
| Power by part of the chip | ✅ | CPU, GPU, Neural Engine, DRAM and the rest, from IOReport and the SMC |
| CPU cluster and GPU clock speeds | ✅ | From IOReport residencies and the device tree's clock tables |
| Memory by app, paging and compressor rates | ✅ | Stacked over time |
| GPU and power by app over time | ✅ | Stacked, with the rest as "Everything else" |
| Privileged helper | ⬜ | Full details for root processes. SMAppService needs a signed build, and until then an on-demand helper is the fallback |
| Flight recorder | ⬜ | SQLite history with a timeline scrubber: "what was hogging the CPU at 3 a.m.?" |
| Alerts | ⬜ | Notify when a process holds a resource above a threshold, or on memory pressure and thermal throttling |
| Per-process network throughput | ⬜ | Per-socket byte counters |
| "Who is using…" | 🚧 | Port, file or volume to process. `otm ports` exists; the UI and "can't eject" helper are planned |
| Sensors | ✅ | SoC power rails, die, SSD and battery temperatures, and fan speeds with their range |
| Prometheus / OpenMetrics exporter | ⬜ | `otm serve` for homelab dashboards |
| Dock tile live graph | ⬜ | Optional, like Activity Monitor |
| Widgets | ⬜ | WidgetKit gauges |
| Themes | ⬜ | Including a retro green-on-black skin |
| Signed, notarized releases with auto-update | ⬜ | Needs an Apple Developer account; Sparkle for updates; Homebrew cask |

## Release plan

- **0.1**: what's above marked ✅, plus README screenshots. The repository goes
  public, CI runs on every push, and releases are ad-hoc signed.
- **0.2**: startup items, services, the flight recorder and alerts.
- **0.3**: privileged helper and the exporter.
