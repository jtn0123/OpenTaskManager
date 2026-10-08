# OpenTaskManager: notes for Claude

Native macOS task manager. Swift 6 with strict concurrency, SwiftUI plus AppKit,
macOS 14+. GPL-3.0, clean-room: never copy code, artwork or text from Task
Manager OG or any other proprietary task manager.

## Build and test

- Use the Makefile: `make build`, `make run`, `make test`, `make cli`, `make lint`.
  It points `DEVELOPER_DIR` at full Xcode, because `xcode-select` may point at
  the Command Line Tools, which lack xcodebuild and Swift Testing. For raw
  `swift`, `xcodebuild` or `swiftlint` commands, export
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (or
  Xcode.app) first.
- `project.yml` is the source of truth. The `.xcodeproj` is generated and
  ignored; new files under `App/Sources` are picked up by `make generate`.
- All tests must pass and lint must be clean (`swiftlint lint --strict`).
  Never suppress warnings or skip tests.

## Layout

- `Packages/OTMKit`: sampling library (System/, Model/, Monitor/, Format/,
  Graphing/ for axis and curve maths and the squarified `Treemap`;
  System/LaunchItems, LaunchTriggers and Launchctl read launchd plists and
  parse `launchctl` output; System/DiskUsageScanner walks a folder for the
  Storage page and `otm du`, with the category rules in Model/DiskCategoryRules,
  keeping to its own volumes by volume and by mount point (`MountBoundary`, which
  keeps a scan of /System out of the Data volume, from System/MountTable) and
  counting hard links once by device and inode (`HardLinkLedger`), both in
  Model/DiskScanRules;
  Model/DiskScanSummary (a scan's bounded, versioned summary), System/DiskScanHistory
  (the last 10 per scope) and Model/DiskScanComparison (interval diff maths) back
  Storage's Changes mode and `otm du --changes`; Model/DiskReconciliation (the
  remainder, the volume's used space less the scan's, for a whole volume or
  home, a folder's share otherwise, and what could be in it, named with figures
  only where known, never as space to free or wholly as snapshots),
  Model/APFSList (`diskutil apfs list` and `listSnapshots` plists, neither
  needing admin rights) and System/DiskReconciliationReader back Storage's
  "Where the space is" and `otm du --reconcile`;
  System/InstalledApps, MachO and CodeSigning find and read app bundles for the
  Apps page and `otm apps`, and System/AppRemoval finds what an app keeps in
  your Library for its Move to Trash review (tests use a fake home, never
  yours; items go through `NSWorkspace.recycle`, never rm); Layout/ holds the width maths for the details
  pane, `SplitMath`, and the process table's columns, `ColumnFit`;
  System/NetworkQuality (parses `networkQuality -c`) and System/DiskSpeedTest (one
  unlinked temp file, F_NOCACHE reads, verified, cancellable) back the user-started
  speed tests on Performance's network and disk details (`SpeedTestStores`; nothing
  runs per tick; `-openSpeedTest start` starts the `-openResource` detail's for
  screenshots, `LaunchArgument.startsTest(on:)`) and `otm
  netquality` / `otm diskspeed`, with the last few results per interface or volume
  in Application Support/OpenTaskManager/SpeedTests (System/SpeedTestHistory);
  System/CPUBenchmark (versioned workloads in CPUBenchmarkKernels, every unit
  checked, on threads of its own, cancellable) backs the CPU detail's Benchmark
  card (`CPUBenchmarkStore`) and `otm cpubench`, the last 10 per Mac kept beside
  the speed tests; System/ChipLayoutReader (hw.perflevelN, device-tree clusters,
  I/O Registry core counts) backs its Chip layout card and `otm cpubench layout`;
  System/GPUBenchmark (Metal shaders from source in GPUBenchmarkKernels, timed by
  the GPU, every result checked, cancellable) backs the GPU detail's Benchmark card
  (`GPUBenchmarkStore`; debug `-gpuBenchmarkFixture nodevice|unsupported|notiming`)
  and `otm gpubench`, the last 10 per Mac in SpeedTests/gpu-benchmark.json;
  Model/BenchmarkRun adapts those four histories on read to one envelope (never
  rewritten), Model/BenchmarkComparison holds the compatibility rules and change
  against both runs' spread, and Format/BenchmarkExport the versioned JSON and
  Markdown, for Performance's Benchmarks workspace (`BenchmarksDetail`,
  `BenchmarkWorkspace`: Run all through the tests' own stores, picks and ticks in
  UserDefaults, `-openBenchmarkCompare gpu:1,2`) and `otm bench`;
  Model/BenchmarkTrend splits a test's runs into lines only comparable runs
  share and gives each figure's points their spread and verdict against a
  picked baseline (beside each chart's change in a word, "within spread",
  "faster", "lower": `BenchmarkChange.verdictWord`), for the workspace's
  static Swift Charts (`BenchmarkTrendView`,
  `-openBenchmarkBaseline cpu:3`); the resource cards fold their runs into
  `SavedRunsDisclosure`, whose Compare in Benchmarks ticks the latest pair;
  System/CommandRunner runs every system tool with a timeout),
  the `otm` CLI, and Swift Testing tests. Keep pure logic here so it can be
  tested.
- `App/Sources`: `AppModel` (observable state and history), Views/Overview,
  Views/Processes (NSOutlineView table in `ProcessOutlineView`), Views/Performance,
  Views/History (the flight recorder's graphs; `FlightRecorder` in OTMKit writes
  a `HistoryRecord` every 10 s to ~/Library/Application Support/OpenTaskManager,
  and saved sessions beside them; `RecordingFile` in OTMKit is the versioned
  `.otmrecording` format, which `HistoryRecordingStore` opens into an in-memory
  recorder, and `-openRecording <path> -openPlayback 1|10|60` opens and plays one;
  events, `HistoryEvent` (app launches and quits from NSWorkspace, busy background
  processes from `ProcessEventTracker`, network changes, sleep and wake), go in the
  same database, its schema migrated by `PRAGMA user_version`, and in a file's
  optional `events` key; hardware series (`HistoryHardwareSample`: core-type and
  per-CPU loads, cluster clocks, the hottest dies, fans and power rails picked from
  `SensorTable`'s rows, null where unread) go in each record's `hardware` blob
  (schema 2, series named once in `hardware_series`) and a file's optional,
  separately versioned `hardware` block, charted under History's folded Hardware
  section; process history (schema 3, OTMKit's FlightRecorderProcesses): every
  process seen gets a `process_lifetimes` row by `ProcessIdentity` (name, path,
  user, bundle ID, launchd label once Startup has read launchd's list, first and
  last seen, ended), its last sighting moved on through its run's one
  `process_watches` row, so a record writes only starts and ends;
  `ProcessHistoryTracker` takes each record's average CPU and disk from the
  cumulative counters the sampler already reads (no new reads per tick), and
  `ProcessHistoryKeep` keeps figures only for the 5 largest footprints, busy disk
  and CPU users, 40 at most, so a missing row while it ran is "idle, not stored",
  never zero, and a stretch without records a gap; History's Processes section
  (`HistoryProcessStore`, `HistoryProcessSection`) searches lifetimes by name,
  path, label or PID and charts one, marked on the rail and in the moment panel,
  the process inspector's Show History opens it, `-openProcessHistory <query>`
  searches it and picks the latest match, and `otm history processes <query>`
  prints it; recording files carry no process history yet; Compare's figures, `HistoryIntervalStats` and
  `HistoryComparison`, leave gaps out, and Layout/CompareBrackets places its A
  and B brackets over the rail; each interval's column heading gives how much
  of it was recorded, and `HistoryComparison.limitation` (a side under
  `lowCoverage`, or under `unevenCoverage` of the other's share) puts a notice
  over the figures, with Compare Recorded Overlap when `recordedOverlap()`
  finds a minute or more both recorded at the same offsets (one-step holes
  bridged), which narrows A and B to it until Back to Full Stretches;
  `-openHistoryCompare <minutesAgoA>,<lengthA>[,<minutesAgoB>,<lengthB>]`
  opens Compare with them picked, counted back from the range's end, with B the
  same length before A when left out; the pinned rail folds to a strip (the
  section at the top, the span, the moment, Play and speed, a slim track that
  marks spike events) once the charts' top has scrolled under it, and comes
  back whole at the top or
  from the strip's button: `RailFold` in OTMKit's Layout/ holds the rule, and
  `HistoryPageScroll` follows the clip view's bounds, so it moves only on
  scroll, never per tick, and only `HistoryPinnedRail` reads it, so the charts
  never reload; spike captures, off until "Capture spikes automatically" (Settings'
  History section, or the switch in History's Spikes toolbar list) is on: each
  update's figures go into `SpikeRecorder` in OTMKit, a preallocated ring of about
  2 min of samples with the top 5 CPU, top 5 memory and top 3 disk processes (name,
  PID, start time), whose `SpikeTriggers` fire on the whole CPU at 80% or more for
  10 s (until under 70%), memory pressure at warning or critical, thermal pressure
  at serious or critical, and disk or network 4 times a 5-minute rolling baseline
  (and over 64 MB/s or 8 MB/s) for 10 s, each kind then cooling down 10 min; a
  trigger keeps the 2 min before and carries on 1 min, then `SpikeCaptureStore`
  writes the `SpikeCapture` off the main actor, as a recording of 1-second records
  with a `.spike` event and a file's optional, separately versioned `incident`
  block (`SpikeIncident`: what crossed, when, the contributing processes), to
  Application Support/OpenTaskManager/Captures (`SpikeCaptureLibrary`: newest 20,
  at most 100 MB); a replay's `FlightRecorder.recordSpan` is the file's record
  length, so it buckets by the second; a `-sensorFixture` run captures nothing;
  `-captureSpikeNow cpu|memory|thermal|disk|network` (debug builds) forces one 15
  updates in, `-openSpikes YES` opens the list, `otm captures [--json]` lists them),
  Views/Connections (socket table; `ConnectionStore` runs the walk),
  Views/Startup (launchd items in a SwiftUI `Table`, scanned off the main actor
  when the page opens and on Refresh, never per tick; while it's on screen
  launchd's list alone, no plists, is read again every 10 s and noted in
  `LaunchJobStore`, whose `LaunchJobWatch` in OTMKit counts restarts by label,
  scope, PID and start time and names failed, crashed and restarting jobs for
  the Problems filter; `LaunchItemStatus` in OTMKit is the one label for what
  a job is doing (Running, Restarting, Crashed, Failed · exit code 1, Not
  running, Disabled, Not loaded) that the Status column, the details' header
  and the Apps page share, with launchd's Loaded or Not loaded on a line of
  its own, never in its place ("exit 1" where the column is narrow, the rest
  in its tooltip); the details put Program right under it, and a notice
  (`LaunchJobHealth.notice`) only where it adds something: what a known code
  or a crash signal means, a failure before the run now, restarts seen; the CPU and Memory cells look launchd's PID up in the
  latest sample themselves, so a tick redraws them, not the table),
  Views/Apps (installed apps in a SwiftUI `Table`; `InstalledAppStore` scans off
  the main actor when the page opens and on Refresh, then streams bundle sizes in
  from a few GCD threads, and follows launches and quits through NSWorkspace,
  never per tick),
  Views/Users (per-user totals; the grouping is `UserUsageBuilder` in OTMKit),
  Views/System (hardware and security facts, read once when the page opens, never
  per tick; the rows come from `SystemReport` in OTMKit, and attached devices from
  one `system_profiler -json` run, `PeripheralReader` in OTMKit's System/Peripherals,
  again on Refresh; Save Report… and `otm system report` write `SystemReportDocument`,
  whose JSON schema is `SystemReportJSON`, with identifiers left out unless asked;
  the network cards' addresses, routes, DNS and proxies come from
  `NetworkConfigurationReader` (SCDynamicStore, `getifaddrs`, a route dump,
  CoreWLAN without the SSID, which needs Location), also read on Refresh and
  printed by `otm netconfig`, with locations (SCPreferences, read-only), shares
  from the mount table (`getfsstat` with `MNT_NOWAIT`, never the server) and the
  firewall's settings (`FirewallReader`: `system_profiler` and `socketfilterfw`,
  no root, so never pf; settings, never a claim of reachability); memory type,
  storage controllers, SD and smart-card readers come from one lazy
  `system_profiler` run a session, `HardwareInventoryStore`, and `otm hardware`),
  Views/Drivers (system extensions and kexts in a SwiftUI `Table`, scanned off
  the main actor when the page opens and on Refresh, never per tick; parsing is
  in OTMKit's System/Extensions, SystemExtensionList and KernelExtensionList),
  Views/Storage (disk space: `StorageStore` keeps the session's last scan and
  scans only on Scan or a scope pick, never on launch or per tick; the treemap
  is laid out once per scan, folder and size, drawn in a `Canvas`, and its hover
  layer alone reads the pointer; each finished scan's summary is saved once, off
  the main actor, to Application Support/OpenTaskManager/Scans, and the Changes
  list colours the treemap by what changed since an earlier scan; the change
  picked there is named above the map, not in a tag over it (`PickedChangeBar`:
  its trail with the outlined folder underlined, why the map can only outline
  what holds it, `TreemapReach` in OTMKit, then Open, which keeps Changes, and
  Reveal in Finder); "Where the space is" (`StorageReconcilePanel`), folded at
  first, reads the volume's figures once per finished scan, off the main actor),
  Components/Graphs (graphs, gauges, cards), and Support (icons, hot key, menu bar icon).

## Performance rules (the app must stay light)

- Don't attach SwiftUI `.animation` or `.contentTransition` to values that
  change every tick. Each animation frame re-runs layout for the whole window;
  on the Overview page this cost about 75% of a core. Animate with Core
  Animation layers instead (see `RingGaugeView` and `CoreTileRowView`), which run
  in the render server.
- No blur filters or `.shadow` on views that redraw every tick. Fake the glow
  with wide translucent strokes, or use CALayer shadows with a `shadowPath`.
- The process table updates rows in place: `OrderedDiff` moves, inserts and
  removes rows, and visible cells are restyled. Don't go back to calling
  `reloadData()` every tick. It sorts by each figure as shown (`ShownFigure`),
  so rows that read the same keep PID order rather than swapping every tick.
- The Thermals table (`SensorTableView`) is AppKit rows made only when the set
  of rows changes; a tick sets just the figures that changed. Its rows and
  ranges are `SensorTable` and `SensorExtremes` in OTMKit. Its header (the
  since line, Reset and the column titles) pins to the page's visible top by
  watching the enclosing clip view's bounds (`StickyHeader` in OTMKit), so it
  moves only on scroll, never per tick; rows are added below it.
- Graphs go through `GraphView` (`StreamGraph.swift`): paths are rebuilt once
  per sample and a Core Animation scroll slides them between samples. Changing
  numbers go through `AnimatedNumber`, which composes cached glyph bitmaps.
  Don't swap either for SwiftUI `Path` or `Text` animations. The History page
  is the exception: its graphs are static Swift Charts, reloaded once per graph
  point, and its scrubber line is an overlay that alone reads the pointer, so
  hovering never redraws the charts. Playback moves the scrubber's playhead,
  apart from a pin or a preview, and gaps (`HistoryGap` in OTMKit) are drawn
  with the charts, so neither does replay. Until a live graph's window fills, the
  stretch before its first sample is a light neutral wash with a faint hatch in
  the scroller (`UnrecordedLook`, which History's gaps share; paths built once
  per size, only moved per sample), labelled only by its footer caption, "40 s
  collected · 5 min window", a `CATextLayer` reset only when the rounded figure
  from `GraphCoverage` changes.
- Graphs on one page cover the same window under a `TimeAxis` ("Last 5 min …
  now"): `AppModel.graphSpan` on Performance, by-app graphs too (each process's
  history, and each app group's as it stood each tick, is as long, `Float`,
  appended in place, ranked by running totals, `ProcessTotal` of OTMKit's
  `RunningSum`, never re-summed; a graph reads one ring per app), `AppModel.shortGraphSpan` on Overview. Top lists (`TopAppsCard`) skip figures that read as zero and hold
  their room for 30 s (`TopListRoom` in OTMKit), so the page doesn't jump;
  the idle line under the rows is a footer shorter than a row
  (`TopListRoom.height`), so a sparse list alone in its row stays compact.
  Performance's Fit collected data toggle (`GraphFit`, in the main graph's
  time axis until the window is nearly full) narrows that one window, through
  the `graphWindow` environment value, in steps (`GraphCoverage.fittedCapacity`),
  never per tick, so the graphs keep scrolling. A reading a Mac never gives
  (a VM GPU's load) takes `Unavailable.symbol` and a short label, never the
  unrecorded hatch. The Overview keeps one card order at every width.
- Rows of cards go through `FillGrid`, not an adaptive `LazyVGrid`: it fills
  every row edge to edge and evens out card heights, so a card that isn't
  available on this Mac (no GPU, no power sensors) never leaves a hole.
  Cards whose lengths differ a lot (the System page's, which depend on the
  Mac and what's plugged in) go through `ColumnGrid` instead: columns that
  each run their own length (`GridMath.packColumns`), one in a narrow window.
  The System page's jump bar and search (`SystemNavigator`; the matching is
  `SystemReportSearch` in OTMKit) scroll to stable ids (`SystemTarget`) through
  a `ScrollViewReader`, and follow the scrolling from the clip view's bounds.
  The bar is in-page links, not tabs: "Jump to" and a link per group, the one
  at the top underlined (a menu when narrow). A search marks its finds in the
  cards' titles, labels and values (`SearchMarks`, ranges from
  `SystemReportSearch.highlights`, which folds as the matching does), outlines
  the match gone to, and puts Clear Search beside its count.
- The Connections page's socket walk (`ConnectionSampler`, every process's
  descriptors) is too heavy for the main sampler's tick. `ConnectionStore`
  runs it off the main actor every 3 s, only while the page is on screen.
  Anything on that page that changes every tick (the traffic card) reads the
  model in its own view, so the table isn't rebuilt each second.
  `ConnectionWatch` (OTMKit, pure) diffs the walks into observed lifetimes:
  sockets keyed by `ProcessIdentity`, descriptor, protocol and kernel handle,
  with endpoints that must carry on, so a reused descriptor or PID is a new
  socket. It feeds the "Seen for" column (time this page has seen a socket,
  never its age), New on listeners seen opening (5 min), the details'
  timeline, and Closed recently (15 min, at most 200; empty, it says since
  when it's been watched without a gap, `closedCoverage`, with Show Open
  Sockets, under counts headed "Open now"). `ConnectionStore.shared`
  lasts the session, so time away from the page shows as an unwatched gap.
- Budget: each page should use under about 10% of one core in a debug build.
  Measure CPU time over 20 s or more, not `ps %cpu`, and only once the graphs'
  5-minute windows have filled (about 5.5 minutes after launch): work that
  grows with the history drawn and summed once made a reading at launch two to
  three times low. Readings swing with the Mac's load, so compare two builds
  side by side, read at the same moments. Most of a full page's cost is SwiftUI
  re-evaluating and laying out what reads the tick, Core Animation commits and
  the menu bar item, so keep what changes every tick in small views that read
  the model themselves.
- Code that runs for every point of every graph each tick (`GraphMath`'s
  tangents, stacks and sums, `History.addValues`, `StreamGraph`'s traces and
  curves) is while loops over buffer pointers: in a debug build a range's
  iterator, an array's subscript, `enumerated()`, lazy filters and generic
  `max()` each cost a call per point. Don't read `NSRunningApplication`
  properties per tick either: even `processIdentifier` can wait on a
  LaunchServices round trip; `AppModel` rebuilds its app list when NSWorkspace
  reports a launch or quit.

## Screenshots and UI checks

Never click or script the UI while the user is at the machine, and never bring
the app to the front. Launch it in the background, then capture its window by ID:

```sh
open -g -n .build/xcode/Build/Products/Debug/OpenTaskManager.app --args -openPage Overview
screencapture -x -o -l <windowID> out.png
```

`-openPage Overview|Processes|Performance|History|Connections|Startup|Apps|Users|System|Drivers|Storage` sets the starting page, and
`-openResource cpu|memory|gpu|disk|network|power|sensors|benchmarks` the Performance detail
(`-openScroll bottom` starts the page scrolled to the end), `-openProcess <pid>`
selects a process so its inspector shows, `-openProcessHistory <query>` (with
`-openPage History`) searches History's Processes section and charts the latest
match, `-openConnection <port or text>`
selects the first matching socket on the Connections page so its details show
(`-openConnectionList closed` starts it on Closed recently),
`-openStartupItem <text>` selects the first startup item whose label or name contains it,
`-openApp <name or bundle ID>` selects and scrolls to an app on the Apps page
(add `-openAppRemoval YES` to open its Move to Trash review),
`-openDriver <text>` selects the first extension on the Drivers page whose name
or bundle ID contains it (switching the Third party/Apple filter if it hides it),
`-openUser <name>` opens that user's top processes on the Users page (and
the system accounts, for root or a service account), `-openSystemSearch <text>`
searches the System page and `-openSystemCategory network` (or another group
in its jump bar) scrolls it to that group, and
`-openStorageScope <path>` scans that folder or volume when the Storage page
opens, with `-openStorageFolder <path inside it>` opening a folder in the
results, `-openStorageList largest|changes` showing the largest files or
what changed since the last saved scan of that folder, and
`-openStorageReconcile YES` unfolding "Where the space is". Pick a
scope without protected folders (`/Library`, `/usr`, a test folder): Desktop,
Documents, Downloads and other apps' containers raise a privacy prompt. Don't pass
`-page` itself: a launch argument pins that setting for the whole run, so the
sidebar stops working in that instance. The exception is a capture while other
instances run: `-openPage` saves the page, so every running instance follows
the last launch, and `-page <name>` keeps a throwaway instance on its page. Get the
window ID from `CGWindowListCopyWindowInfo`. Capture fails while the screen is
locked or the window is on another Space.

A Mac or VM with no sensors can still show a full Thermals page: in a debug
build, `-sensorFixture <file>` loads a recording from
`otm sensors --extremes 20 --json` in place of the sensors (`SensorFixture`).
Such a run records nothing to History, since the readings aren't that Mac's.

## Conventions

- Process CPU is stored as Activity Monitor-style percent (100 = one core) and
  displayed through `CPUScale`, which defaults to share of the whole CPU.
- Restricted processes (root and other users) only have CPU and memory, read
  via `/bin/ps`. Show "—" for other fields, never zero.
- When the process table runs out of width it hides optional columns, lowest
  `ProcessColumn.priority` first (the maths is `ColumnFit` in OTMKit's Layout/),
  apart from the user's Columns choices, and shows them again when there's room.
  A column this Mac can't fill (Power, when `AppModel.measuresProcessEnergy`
  is false; GPU, when `reportsProcessGPU` is, because no process had any GPU
  time for a few samples; ANE memory, likewise from `reportsProcessNeuralMemory`,
  both settled by `ProcessFigureReporting` in OTMKit) starts hidden the
  same way; the Columns menu says why, and the user can still turn it on. An
  idle GPU still reports (0%); a VM's paravirtual GPU does too. ANE memory is
  `rusage_info_v6`'s neural footprint (macOS 15+, read in the same rusage
  call): memory held for the Neural Engine, never shown as how busy it is.
- The Connections table hides columns to fit the same way (`ConnectionColumn`,
  Protocol first, then PID, then Seen for, then Scope; Process, Local, Remote and State
  always stay), and endpoints cut the address in the middle, never the port.
  Its six summary cards fold into a strip of chips (rows from
  `GridMath.stripRows`) when they don't fit one row or the details are open,
  so the table keeps its height; a mouse-opened pane folds them a
  double-click later, so the second click still lands on the same row.
  The Startup table hides columns to fit too, through the shared `FittingColumn`,
  `TableColumnFitter` and `TableColumnSqueeze` (Components/ColumnFitting), in
  `StartupColumn`'s order (OTMKit's Layout/): Launches first, then Publisher,
  Memory, CPU and last Kind, so Name and Status keep their room and a narrow
  table still says Agent or Daemon.
- The process inspector shows one process. When the selected row has others
  nested under it, whose sum the collapsed row shows, a note under its header
  says so with the row's figures and a Show Helpers button that expands it. Its
  memory graph and facts name their measure (footprint, as in the Memory
  column, beside real memory), defined in `MemoryMeasure`.
- A process is its PID and start time (`ProcessIdentity` in OTMKit): the
  table's selection, the inspector and `AppModel.processHistory` go by it, so
  a PID macOS reuses never inherits another process's graphs, selection or
  End Task. The inspector's Overview adds counters read for that one process
  each tick (`ProcessDetailReader`: peak footprint, faults, page-ins, context
  switches, QoS; per field "Needs admin rights" for others' processes) and its
  ancestry (`ProcessAncestry`), each step selecting that process; its Threads
  tab reads the threads off the main actor once per tick, only while shown
  (`ThreadActivityTracker`), as does `otm threads`; rows stay one line, and
  a clicked thread's whole name, selectable, with Copy Thread Name, is pinned
  under the list (`ThreadDetailLine`). `-openProcessTab
  threads|files` opens a tab with `-openProcess`.
- The inspector's Group tab (`-openProcessTab group`) is offered only for a
  row with others nested under it, and the note's "See all N together" link
  opens it.
  It shows the whole group, whatever the search: `ProcessGroup` in OTMKit lists
  the members by identity, each with its `ProcessGroupReason` (macOS holds the
  root, or a member, responsible for it; in Tree, it was started by one), and
  `ProcessGroupFigures` adds them up (memory as summed footprints, which can
  count shared memory more than once; disk, GPU and power only where read).
  Its CPU graph is `AppModel.appGroupHistory` in Grouped; Tree keeps no group
  history, so it adds up the current members' own. A member's name selects it
  in the table, expanding the rows above it. End and Force Quit, titled with
  how many they'd end ("End 2 Processes…", "Force Quit 2…"), first
  list every target by name and PID, fixed when clicked, end the furthest from
  the root first, check each one's identity again just before
  (`ProcessGroupEnding`), and leave others', the system's and this app's
  processes alone; a group whose root isn't yours (launchd's in Tree) can't be
  ended. `ProcessTreeBuilder` follows a responsible PID only to a process that
  started before the one naming it, so a reused PID never collects an ended
  app's helpers.
- Pages with a table and details (Processes, Startup, Apps, Drivers,
  Connections) use `InspectorSplit`: the pane appears beside the table once
  something is selected, its width is draggable and remembered, and in a
  window too narrow for both it covers the table under a Back button (Esc).
  Double-click opens it. Give it the table's real minimum width. A covered
  table is moved out of the window, not just hidden: AppKit still shows the
  tooltips of a transparent view, over the details.
- In a details pane beside a table, wrapping text outside the pane's scroll
  view shouldn't use `.fixedSize(horizontal: false, vertical: true)`: inside
  the window's split view it made the page take the pane's height and pushed
  the status bar out of a 730-point window. Plain wrapping text is enough.
  The pane's minimum height also sets the page's, so a tall pinned part
  (Startup's state and Start Now or Restart/Stop) is pinned only when the
  measured heights leave room, and otherwise scrolls, name and all, with the
  rest (see `StartupItemDetail` and `ConnectionDetail`; a fallback that kept
  the name pinned still pushed the status bar out of a 560-point window, and
  `ViewThatFits(in: .vertical)` measured both layouts again on every tick).
- A details pane has one scroll view, edge to edge between a pinned header and
  a pinned footer of actions, with dividers at both ends. Long technical values
  fold away in a `DetailDisclosure` (Startup's arguments, an app's certificate
  chain). A path shows its name over its folder, which wraps and can be
  selected (`CopyableText(splitsPath: true)`, `PathParts` in OTMKit), the whole
  path in its tooltip and copied whole, with Copy Path beside Reveal in Finder:
  one control, never a scroll view of its own. Identifiers too long for their
  line (a UUID) keep to one, cut in the middle (`truncatesMiddle`).
- A row picked outside its table (a launch argument, another page, Show in
  List) or moved by the user's filter, search or sort is brought into view
  once; a tick or a background re-read never scrolls a table. SwiftUI's
  `ScrollViewProxy` didn't move the Startup table once it was on screen, so it
  uses `TableRowReveal`, which asks the AppKit table.
- Performance and History fit the narrowest window (820 points with the
  sidebar shown) without clipping or scrolling sideways. Performance's resource
  list is an `HStack` column sized from the page width, not an `HSplitView`,
  whose minimum widths pushed the page past both window edges; where the detail
  would get under 560 points beside it, the list gives way to a row of resource
  chips over the detail. Disks there go by volume or image-file name, diskN
  second (`DiskNaming` in OTMKit, read by `DiskNameReader` only when the disk
  or mount list changes), with disk images under a folding "Disk images"
  heading or chip. Below 760 points History moves its moment panel into
  a summary over the charts.
- In a window under 900 points the sidebar hides itself and comes back when
  the window widens; a hide in a wide window is remembered (`sidebarHidden`)
  and a show in a narrow one lasts until the window crosses 900
  (`SidebarVisibility` in OTMKit). The View menu lists the pages (⌘1 to ⌘9).
  With it hidden, a page menu (`PageSwitcher`: one list glyph and a chevron,
  "Pages", whatever the page, out of the toolbar's glass so it sits with the
  title, not the live badge) sits before
  the title, and in a narrow window Pause drops its word to make room, as do
  the pages' own items (`compactToolbar`: Startup's, Apps' and Drivers' read
  time loses "Read at" to its tooltip, Processes' Columns becomes a submenu
  of its View menu); keep
  the title visible, since hiding it (macOS 26) sent the sidebar toggle to the
  overflow menu for good once the sidebar was shown narrow. `PageFocus` gives the focus to the page's main table, or to
  nothing, never the toolbar's toggle (`HiddenSidebarFocus`). The detail column
  takes the window's height whatever its page asks for: a taller page moved the
  split view up and left a toolbar backdrop as a white band over the page.
  The toolbar's live badge speaks for the sampled metrics alone; Startup, Apps
  and Drivers say when their lists were read beside their Refresh
  (`InventoryRefresh`).
- The CPU graphs (Performance's, per core type, per core, by app, and History's
  CPU chart) share one Auto / 100% setting, `CPUGraphScale` (`cpuGraphScale`).
  Auto bounds are `AutoScale` in OTMKit's Graphing/: round steps from 10%, grown
  at once, shrunk only after the data stays low; `AutoScaleBounds` keeps each
  live graph's between samples, and the top label says "auto scale". Keep
  segmented pickers on a live page out of `ViewThatFits`: it measured them
  again every tick (about half a percent of a core for the CPU graph's two),
  so that caption row is a small `Layout` instead.
- History's chart legends draw a sample of each line as it's stroked
  (`HistoryLine.Stroke`, solid, dashed or dotted, over its fill when it has
  one), so two lines on a chart never differ by colour alone, and give what
  the line and its figure mean in the tooltip. During a replay the toolbar says
  "Collecting · 1 s" for this Mac and "Replay · 10×" for the file; the
  recording's name is the page banner's.
- Graph colours come from the palette picked in Settings (`GraphColors`; the
  presets, Standard, Color-blind friendly and High contrast, are data in
  OTMKit's `GraphPalette`; `-graphPalette colorBlind|highContrast` picks one
  for a run). Read them through `Theme` in a view's body, so a change redraws
  the view; AppKit views that keep colours compare `GraphColors.shared.revision`
  (see `SensorReadingTable`). "By app" graphs colour apps with
  `Theme.appColors(for:in:)` (`SeriesSlots`), so an app keeps its colour as the
  ranking changes.
- Secondary text (labels, captions, units, footnotes) takes
  `.foregroundStyle(.secondaryText)` and `.font(.metadata)` (12 pt, the
  floor for anything a reading depends on); explanations meant to be read
  (what a reading means, why it's missing, what a button does)
  `.font(.explanation)` (12 pt); and table and list rows, graph legends and
  the process inspector's facts `.font(.tableText)` (13 pt), all from
  `Graphs.swift`. Live graphs' axis labels and coverage caption are 12 pt
  too (`StreamGraphView.captionFont`), placed so the caption still fits under
  the middle label of the Overview's 72-point graphs. The Thermals table's
  rows are 13 pt (body), with its supporting text at 12 pt. Benchmarks'
  comparison table keeps that size in a narrow window by dropping a figure's
  variant under its name and stacking the two spreads (`ViewThatFits`). The
  system's `.secondary` falls under 4.5:1 on the tinted cards (see `TextTone`).
  Search finds are marked in primary ink, bold, over `TextTone.highlight`,
  which keeps 4.5:1 on every card in both appearances.
  A SwiftUI `Table` that may hold only a few rows takes `.fitsTableToRows(_:)`
  (`TableFit.swift`), so no empty striped rows follow the last one.
- Commits end with the Co-Authored-By trailer. Only push to github.com/jtn0123.
