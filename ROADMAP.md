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
| App history (resource use per app over days) | 🚧 | The flight recorder keeps each stretch's five busiest apps by CPU and memory; full per-app graphs over days are planned |
| Startup apps | 🚧 | LaunchAgents and LaunchDaemons with status, PID, triggers and publisher are done. Login Items and the background items apps register need root to read, so they wait for the privileged helper; for now the page opens their System Settings pane |
| Enable and disable startup items | 🚧 | Third-party agents switch in your own session with `launchctl disable`/`enable` plus `bootout`/`bootstrap`, after a confirmation, and Enable undoes it. Daemons wait for an administrator prompt; Apple's agents are left alone |
| Users tab | 🚧 | Per-user totals, history, sessions and top processes are done; logging off other sessions is planned |
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
| `otm` CLI with JSON output | ✅ | `ps`, `top`, `system`, `power`, `ports`, `drivers`, `inspect`, `kill`, `du` |
| Overview dashboard with live core map | ✅ | |
| Power by part of the chip | ✅ | CPU, GPU, Neural Engine, DRAM and the rest, from IOReport and the SMC |
| CPU cluster and GPU clock speeds | ✅ | From IOReport residencies and the device tree's clock tables |
| Memory by app, paging and compressor rates | ✅ | Stacked over time |
| GPU and power by app over time | ✅ | Stacked, with the rest as "Everything else" |
| System information page | ✅ | Hardware, displays, storage, network, battery health, software and security state; identifiers hidden until shown; Copy Summary |
| Drivers page | ✅ | System extensions (network, DriverKit, endpoint security) and loaded kernel extensions, third-party first, with publisher, status, and approvals that are waiting flagged and linked to System Settings. Kexts show their UUID, path, memory and links. Read on open and on Refresh. Also `otm drivers`. Connected devices (USB, Thunderbolt, PCI) aren't listed yet |
| Disk space analysis (Storage page) | ✅ | Scan Home, a volume or any folder: drill-down treemap, ranked contents, the 50 largest files and space by category, with Reveal in Finder and Copy Path. Allocated sizes, hard links counted once, bounded memory. Also `otm du` |
| Move to Trash from the Storage page | ⬜ | TODO: Move to Trash (never delete outright) for items picked on the Storage page, with a confirmation that shows the size and an Undo, then update the totals without a rescan. Left out until then because it's destructive |
| Privileged helper | ⬜ | Full details for root processes, including their sockets. SMAppService needs a signed build, and until then an on-demand helper is the fallback |
| Flight recorder | ✅ | SQLite history every 10 s, kept 7 days, with a scrubber that shows the busiest apps at any moment: "what was hogging the CPU at 3 a.m.?" |
| Alerts | ⬜ | Notify when a process holds a resource above a threshold, or on memory pressure and thermal throttling |
| Per-process network throughput | ✅ | By app or process from `nettop` every 3 s, only while shown: stacked on Performance → Network and as Top Network on the Overview. Also `otm net` |
| Connections page | ✅ | Every TCP and UDP socket by process, with state, scope (loopback, local network, internet) and listeners reachable from the network flagged. Your own processes only until the privileged helper |
| "Who is using…" | 🚧 | Port to process is done (the Connections page and `otm ports`). File and volume to process, and the "can't eject" helper, are planned |
| Sensors | ✅ | SoC power rails, die, SSD and battery temperatures, and fan speeds with their range |
| Prometheus / OpenMetrics exporter | ⬜ | `otm serve` for homelab dashboards |
| Dock tile live graph | ⬜ | Optional, like Activity Monitor |
| Widgets | ⬜ | WidgetKit gauges |
| Themes | ⬜ | Including a retro green-on-black skin |
| Signed, notarized releases with auto-update | ⬜ | Needs an Apple Developer account; Sparkle for updates; Homebrew cask |

## Release plan

- **0.1**: what's above marked ✅, plus README screenshots. The repository goes
  public, CI runs on every push, and releases are ad-hoc signed.
- **0.2**: startup items, services and alerts.
- **0.3**: privileged helper and the exporter.
