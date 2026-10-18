# Roadmap

The aim is everything a Windows-style task manager on the Mac should do, then a
good deal more. ✅ done · 🚧 in progress · ⬜ planned

## Task Manager parity

| Area | Status | Notes |
| --- | --- | --- |
| Processes grouped as Apps / Background / System | ✅ | Grouped by macOS "responsible process", so helpers sit under their app |
| Tree and flat views | ✅ | |
| Collapsed groups show totals | ✅ | |
| Recently ended processes | ✅ | Processes → Ended recently keeps the last observed readings for 60 seconds, up to 200 identities. Read-only details load ending evidence on selection; PID reuse, sampling gaps and scope changes are handled separately from observed exits |
| End task, end process tree, force quit | ✅ | Apps quit politely first |
| Column chooser, sorting, saved column layout | ✅ | Right-click the header |
| Heat shading of busy values | ✅ | Meter bars, coloured per resource |
| Performance: CPU, memory, disk, network, GPU graphs | ✅ | Plus power and battery. Graphs scroll smoothly and auto-scale |
| Per-core CPU graphs | ✅ | Grouped by core type |
| Status bar summary | ✅ | |
| Always-available shortcut (⌃⇧⎋) | ✅ | |
| App history (resource use per app over days) | 🚧 | The flight recorder keeps each stretch's five busiest apps by CPU and memory; full per-app graphs over days are planned |
| Startup apps | 🚧 | Opens on third-party login registrations, including disabled agents and app-bundled login helpers; the full launchd inventory is a second view. Status, PID, triggers and publisher are shown. macOS keeps background approval switches and Open at Login apps private; the page links to their System Settings pane |
| Enable and disable startup items | 🚧 | Third-party agents switch in your own session with `launchctl disable`/`enable` plus `bootout`/`bootstrap`, after a confirmation, and Enable undoes it. Daemons wait for an administrator prompt; Apple's agents are left alone |
| Users tab | 🚧 | Per-user totals, history, sessions and top processes are done; logging off other sessions is planned |
| Services tab | 🚧 | The Startup page's details show each job's state, run count, start reason, priority and last exit reason (`launchctl print`), and start, restart and stop third-party agents. A separate tab for on-demand services, and controls for daemons (privileged helper), remain |
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
| `otm` CLI with JSON output | ✅ | `ps`, `top`, `system`, `power`, `ports`, `drivers`, `apps`, `inspect`, `kill`, `du` |
| Overview dashboard with live core map | ✅ | |
| Power by part of the chip | ✅ | CPU, GPU, Neural Engine, DRAM and the rest, from IOReport and the SMC |
| CPU cluster and GPU clock speeds | ✅ | From IOReport residencies and the device tree's clock tables |
| GPU benchmark | ✅ | FP32 compute, memory bandwidth and fill rate in Metal, timed by the GPU and checked against answers worked out beforehand, with the last 10 runs per Mac. On the GPU detail and as `otm gpubench` |
| Memory by app, paging and compressor rates | ✅ | Stacked over time |
| GPU and power by app over time | ✅ | Stacked, with the rest as "Everything else" |
| System information page | ✅ | Hardware, displays, storage, network, attached devices (USB with hubs, Thunderbolt/USB4 ports and chains, Bluetooth with battery levels, audio and cameras), battery health, software and security state; identifiers hidden until shown; Refresh; Copy Summary; Save Report… as Markdown or versioned JSON (identifiers opt-in). Also `otm devices` and `otm system report [--json] [--all]` |
| Installed apps page | ✅ | Every app in the Applications folders plus Spotlight's finds: version, kind (Apple, App Store, third party), architecture with Intel-only apps flagged for Rosetta, signer and team, size on disk, last opened, running PIDs and the launchd items each app owns. Notarization isn't shown: reading it means validating the whole bundle |
| Uninstall apps (Move to Trash, with their leftovers) | ✅ | The Apps page's Move to Trash review lists what the app keeps in your Library; items go to the Trash, never deleted outright |
| Drivers page | ✅ | System extensions (network, DriverKit, endpoint security) and loaded kernel extensions, third-party first, with publisher, status, and approvals that are waiting flagged and linked to System Settings. Kexts show their UUID, path, memory and links. Read on open and on Refresh. Also `otm drivers`. Connected devices are on the System page; PCI cards aren't listed yet |
| Disk space analysis (Storage page) | ✅ | Scan Home, a volume or any folder: drill-down treemap, ranked contents, the 50 largest files and space by category, with Reveal in Finder and Copy Path. Allocated sizes, hard links counted once, bounded memory. Also `otm du` |
| Move to Trash from the Storage page | ✅ | Clean Up reviews the picked items, flags changed, private, cloud and remote ones, rechecks each just before moving it to the Trash, and reports the space freed; Rescan is offered, never automatic |
| Privileged helper | ⬜ | Full details for root processes, including their sockets. SMAppService needs a signed build, and until then an on-demand helper is the fallback |
| Flight recorder | ✅ | SQLite history every 10 s, kept 7 days, with a scrubber that shows the busiest apps at any moment: "what was hogging the CPU at 3 a.m.?" Sessions marked on the timeline export as `.otmrecording` files that open read-only and play back at 1×, 10× or 60× |
| Alerts | ⬜ | Notify when a process holds a resource above a threshold, or on memory pressure and thermal throttling |
| Per-process network throughput | ✅ | By app or process from `nettop` every 3 s, only while shown: stacked on Performance → Network and as Top Network on the Overview. Also `otm net` |
| Connections page | ✅ | Every TCP and UDP socket by process, with state, scope (loopback, local network, internet) and listeners reachable from the network flagged. Your own processes only until the privileged helper |
| "Who is using…" | 🚧 | Port to process is done (the Connections page and `otm ports`). File and volume to process, and the "can't eject" helper, are planned |
| Graph colour presets | ✅ | Standard, colour-blind friendly (deuteranopia and protanopia) and high contrast in Settings, with a colour of your own per resource; apps keep their colour in "by app" graphs |
| Media-engine activity | ✅ | GPU detail and recorded History show time above the minimum power state for reporting video, ProRes, scaler and codec blocks; unavailable counters stay absent |
| Sensors | ✅ | SoC power rails, die, SSD and battery temperatures, fan speeds, clocks and DC input in one table with lowest and highest since a reset |
| Prometheus / OpenMetrics exporter | ⬜ | `otm serve` for homelab dashboards |
| Floating mini monitor | ✅ | A minute of each meter above other windows, among them or on the desktop, in a corner of any display; opacity, full strength under the pointer, and the meters it shows in Settings |
| Why is my Mac slow? | ✅ | Observations on Overview and in the menu bar popup, with a details sheet: high whole-CPU load, one busy core, GPU activity and named macOS memory/thermal pressure; relevant process rankings show usage, without a health score or causal claims |
| Dock tile live graph | ✅ | Optional CPU or memory history, two minutes at up to one update every two seconds; current percentage, pause marker and normal icon restored when off |
| Widgets | ⬜ | WidgetKit gauges |
| Retro display look | ✅ | Settings → Retro display: live graphs on dark display panels, each resource in its own vivid colour (Color, the default) or all in one (green, amber, cyan, red, yellow or white), figures as lit dots or seven-segment bars, with an adjustable glow. On by default as Dot matrix in Color |
| Manual and optional daily update checks | ✅ | Off by default; unauthenticated stable GitHub Releases metadata, manual download/install; universal ZIP and draft-release packaging |
| Selected disk activity lights | ✅ | Menu bar R/W lights and per-disk popup from existing samples; all physical disks or selected BSD names |
| Fixed percentage graph scales | ✅ | CPU and GPU-time Auto / 100% controls; utilization and pressure already fixed at 100% |
| Signed, notarized releases with auto-update | ⬜ | Needs an Apple Developer account; Sparkle for updates; Homebrew cask |

## Release plan

- **0.1**: what's above marked ✅, plus README screenshots. The repository goes
  public, CI runs on every push, and releases are ad-hoc signed.
- **0.2**: startup items, services and alerts.
- **0.3**: privileged helper and the exporter.
