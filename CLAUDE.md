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
  Storage page and `otm du`, with the category rules in Model/DiskCategoryRules;
  Model/DiskScanSummary (a scan's bounded, versioned summary), System/DiskScanHistory
  (the last 10 per scope) and Model/DiskScanComparison (interval diff maths) back
  Storage's Changes mode and `otm du --changes`;
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
  System/CommandRunner runs every system tool with a timeout),
  the `otm` CLI, and Swift Testing tests. Keep pure logic here so it can be
  tested.
- `App/Sources`: `AppModel` (observable state and history), Views/Overview,
  Views/Processes (NSOutlineView table in `ProcessOutlineView`), Views/Performance,
  Views/History (the flight recorder's graphs; `FlightRecorder` in OTMKit writes
  a `HistoryRecord` every 10 s to ~/Library/Application Support/OpenTaskManager,
  and saved sessions beside them; `RecordingFile` in OTMKit is the versioned
  `.otmrecording` format, which `HistoryRecordingStore` opens into an in-memory
  recorder, and `-openRecording <path> -openPlayback 1|10|60` opens and plays one),
  Views/Connections (socket table; `ConnectionStore` runs the walk),
  Views/Startup (launchd items in a SwiftUI `Table`, scanned off the main actor
  when the page opens and on Refresh, never per tick),
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
  printed by `otm netconfig`),
  Views/Drivers (system extensions and kexts in a SwiftUI `Table`, scanned off
  the main actor when the page opens and on Refresh, never per tick; parsing is
  in OTMKit's System/Extensions, SystemExtensionList and KernelExtensionList),
  Views/Storage (disk space: `StorageStore` keeps the session's last scan and
  scans only on Scan or a scope pick, never on launch or per tick; the treemap
  is laid out once per scan, folder and size, drawn in a `Canvas`, and its hover
  layer alone reads the pointer; each finished scan's summary is saved once, off
  the main actor, to Application Support/OpenTaskManager/Scans, and the Changes
  list colours the treemap by what changed since an earlier scan),
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
  `reloadData()` every tick.
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
- Rows of cards go through `FillGrid`, not an adaptive `LazyVGrid`: it fills
  every row edge to edge and evens out card heights, so a card that isn't
  available on this Mac (no GPU, no power sensors) never leaves a hole.
  `evensHeights: false` keeps each card's own height (the System page's
  attached-device cards, whose length depends on what's plugged in).
- The Connections page's socket walk (`ConnectionSampler`, every process's
  descriptors) is too heavy for the main sampler's tick. `ConnectionStore`
  runs it off the main actor every 3 s, only while the page is on screen.
  Anything on that page that changes every tick (the traffic card) reads the
  model in its own view, so the table isn't rebuilt each second.
- Budget: each page should use under about 10% of one core in a debug build.
  Measure CPU time over 20 s, not `ps %cpu`.

## Screenshots and UI checks

Never click or script the UI while the user is at the machine, and never bring
the app to the front. Launch it in the background, then capture its window by ID:

```sh
open -g -n .build/xcode/Build/Products/Debug/OpenTaskManager.app --args -openPage Overview
screencapture -x -o -l <windowID> out.png
```

`-openPage Overview|Processes|Performance|History|Connections|Startup|Apps|Users|System|Drivers|Storage` sets the starting page, and
`-openResource cpu|memory|gpu|disk|network|power|sensors` the Performance detail
(`-openScroll bottom` starts the page scrolled to the end), `-openProcess <pid>`
selects a process so its inspector shows, `-openConnection <port or text>`
selects the first matching socket on the Connections page so its details show,
`-openStartupItem <text>` selects the first startup item whose label or name contains it,
`-openApp <name or bundle ID>` selects and scrolls to an app on the Apps page
(add `-openAppRemoval YES` to open its Move to Trash review),
`-openDriver <text>` selects the first extension on the Drivers page whose name
or bundle ID contains it (switching the Third party/Apple filter if it hides it),
`-openUser <name>` opens that user's top processes on the Users page (and
the system accounts, for root or a service account), and
`-openStorageScope <path>` scans that folder or volume when the Storage page
opens, with `-openStorageFolder <path inside it>` opening a folder in the
results and `-openStorageList largest|changes` showing the largest files or
what changed since the last saved scan of that folder. Pick a
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
  time for a few samples, `ProcessGPUReporting` in OTMKit) starts hidden the
  same way; the Columns menu says why, and the user can still turn it on. An
  idle GPU still reports (0%); a VM's paravirtual GPU does too.
- The process inspector shows one process. When the selected row has others
  nested under it, whose sum the collapsed row shows, a note under its header
  says so with the row's figures and a Show Helpers button that expands it. Its
  memory graph and facts name their measure (footprint, as in the Memory
  column, beside real memory), defined in `MemoryMeasure`.
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
  (Startup's state and Start Now or Restart/Stop) goes in `ViewThatFits(in: .vertical)`
  with a fallback that scrolls it, name and all, with the rest (see
  `StartupItemDetail`; a fallback that kept the name pinned still pushed the
  status bar out of a 560-point window).
- A details pane has one scroll view, edge to edge between a pinned header and
  a pinned footer of actions, with dividers at both ends. Long technical values
  fold away in a `DetailDisclosure` (Startup's arguments, an app's certificate
  chain) and paths keep to one line (`CopyableText(truncatesMiddle: true)`:
  cut in the middle, the whole path in a tooltip), never a scroll view of their own.
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
- Secondary text (labels, captions, units, footnotes) takes
  `.foregroundStyle(.secondaryText)` and `.font(.metadata)` (11 pt);
  explanations meant to be read (what a reading means, why it's missing, what
  a button does) `.font(.explanation)` (12 pt); and table
  and list rows `.font(.tableText)` (12 pt), all from `Graphs.swift`. The
  system's `.secondary` falls under 4.5:1 on the tinted cards (see `TextTone`).
  A SwiftUI `Table` that may hold only a few rows takes `.fitsTableToRows(_:)`
  (`TableFit.swift`), so no empty striped rows follow the last one.
- Commits end with the Co-Authored-By trailer. Only push to github.com/jtn0123.
