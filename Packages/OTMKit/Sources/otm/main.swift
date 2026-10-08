import Darwin
import Foundation
import OTMKit

let version = "0.1.0"

let usage = """
otm \(version): OpenTaskManager from the terminal

USAGE:
  otm ps [-n COUNT] [--sort cpu|mem|power|gpu|ane|disk|pid|name] [--json]
                                 Top processes; ANE MEM, the memory each holds
                                 for the Neural Engine (not how busy it is),
                                 shows once any process has held some
  otm top [-n COUNT] [--sort KEY] [--interval SECONDS]
  otm system [--json]
  otm system report [--all] [--json]
                                 The app's System page as Markdown, or as the
                                 versioned JSON its Save Report writes; --all
                                 adds serial numbers, UUIDs and addresses
  otm power [--json]           System, CPU/GPU/ANE/DRAM and cluster power,
                                 clocks, adapter and battery flow
  otm sensors [--json]           Every temperature, fan speed, clock and power
                                 rail this Mac reports, grouped by part; --json
                                 gives the raw temperatures, fans and rails
  otm sensors --extremes SECONDS [--interval SECONDS] [--json]
                                 Sample that long and show each reading's
                                 lowest and highest, and the worst thermal
                                 pressure, as the Thermals page's table does
  otm owner <path|port> [--json] Processes holding a file, folder or local port
  otm ports [--json]             Listening TCP/UDP ports of your processes
  otm net [-n COUNT] [--interval SECONDS] [--json]
                                 Processes moving the most network traffic
  otm drivers [--all] [--json]   System extensions and third-party kernel
                                 extensions; --all adds Apple's kexts
  otm apps [--sizes] [--json]    Installed apps: version, kind, architecture,
                                 signer, last opened; --sizes adds disk space
  otm devices [--all] [--json]   USB, Thunderbolt, Bluetooth, audio and video
                                 devices; --all adds serial numbers and addresses
  otm hardware [--all] [--json]  Memory type and maker (slots where there are
                                 any), storage controllers and their drives'
                                 health, SD card readers and smart cards;
                                 --all adds serial numbers and card tokens
  otm netconfig [--all] [--json] Each network port's addresses, router, link,
                                 MTU and flags, then DNS, proxies, default
                                 routes, tunnels, locations and service order,
                                 mounted network shares, and the firewall's
                                 settings (as far as they can be read without
                                 administrator rights); --all adds MAC
                                 addresses and share accounts, and to --json
                                 (which leaves them out, like a saved report)
                                 addresses, routers, DNS servers, proxy hosts,
                                 file servers and shares
  otm inspect PID [--json]       Arguments, environment, open files, memory
                                 (footprint, peak, resident), faults,
                                 scheduling and the processes that started it
  otm threads PID [--sort cpu|time|name|id|state|priority] [--interval SECONDS] [--json]
                                 Each thread's CPU over the interval, CPU time,
                                 state and priority (your own processes, or
                                 any with sudo)
  otm du [PATH] [--depth N] [-n COUNT] [--changes] [--reconcile] [--schedule] [--json]
                                 What's using the space under PATH (default: the
                                 current folder): biggest folders and files,
                                 --schedule lists app schedules without scanning;
                                 space by category; --changes saves the scan
                                 (as the Storage page does) and shows what grew
                                 and shrank since the last saved one;
                                 --reconcile adds where the space is: the
                                 volume's figures, its APFS container and
                                 snapshots, and what the scan doesn't account for
  otm netquality [INTERFACE] [--json]
                                 Internet download and upload capacity and
                                 responsiveness (macOS's networkQuality); fills
                                 the connection for about 20 s
  otm diskspeed [PATH] [--size MB] [--json]
                                 Sequential and 4K random read/write speed where
                                 PATH is (default: a temporary folder on your
                                 home volume), on a test file it always deletes:
                                 1024 MB unless --size, never over a tenth of
                                 the free space
  otm cpubench [layout] [--json]
                                 Integer, floating-point and memory speed on one
                                 worker and on every core, about 20 s; layout
                                 shows the chip's core types, clusters and caches
  otm cpubench --sustained [2|5] [--json]
                                 The floating-point workload on every core for 2
                                 (default) or 5 minutes, timed in 10 s windows:
                                 the first window, the level it held over the
                                 last third, and the thermal state macOS gave
  otm gpubench [--json]          FP32 compute, memory bandwidth and fill rate on
                                 the GPU (Metal), timed by the GPU, about 10 s
  otm bench guided [cpu|gpu|all] [--repeats N] [--json]
                               Quiet-state preflight, discarded warm-up and
                               N measured repeats (default 3), one at a time.
  otm bench [list|compare A B] [--json]
                                 Every saved CPU, GPU, disk, Internet and
                                 sustained result, numbered newest first; compare
                                 shows each figure's change between runs A and B
                                 of one test, how their starts differed, and
                                 refuses runs that don't compare
  otm captures [--json]          The spike captures the app kept: what crossed,
                                 when, for how long, and the busiest processes
  otm history processes QUERY [--range 1h|6h|24h|7d] [-n COUNT] [--json]
                                 History's processes by name, path, label or PID
  otm startup [--source NAME] [--json]
                                 Launchd folders, app registrations and loaded jobs
  otm startup history LABEL [--json]
  otm connections history [TEXT] [--since 1h|24h|7d] [--json]
                                 Stored launch job observations from the last 7 days
  otm kill PID [--signal NAME]   NAME: term (default), kill, int, hup, stop, cont
  otm --version
"""

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let monitor = SystemMonitor()

switch options.command {
case "help":
    print(usage)

case "version":
    print("otm \(version)")

case "ps":
    try await processesCommand(options)

case "top":
    try await topCommand(options)

case "system" where options.positional.first == "report":
    await systemReportCommand(options)

case "system":
    try await systemCommand(options)

case "power":
    try await powerCommand(options)

case "sensors":
    try await sensorsCommand(options)

case "apps":
    appsCommand(options)

case "netconfig":
    await netconfigCommand(options)

case "hardware":
    hardwareCommand(options)

case "devices":
    devicesCommand(options)

case "owner":
    ownerCommand(options)

case "ports":
    portsCommand(options)

case "net":
    try await netCommand(options)

case "drivers":
    driversCommand(options)

case "inspect":
    await inspectCommand(options, monitor: monitor)

case "du":
    diskUsageCommand(options)

case "netquality":
    await netQualityCommand(options)

case "diskspeed":
    diskSpeedCommand(options)

case "cpubench":
    cpuBenchCommand(options)

case "gpubench":
    gpuBenchCommand(options)

case "bench":
    await benchCommand(options)

case "captures":
    capturesCommand(options)

case "startup":
    await startupCommand(options)

case "connections":
    await connectionsCommand(options)

case "history":
    await historyCommand(options)

case "threads":
    try await threadsCommand(options)

case "kill":
    killCommand(options)

default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
