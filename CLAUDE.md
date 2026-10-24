# OpenTaskManager: notes for Claude

Native macOS task manager. Swift 6 with strict concurrency, SwiftUI plus AppKit,
macOS 14+. GPL-3.0, clean-room: never copy code, artwork or text from Task
Manager OG or any other proprietary task manager.

## Build and test

- Use the Makefile: `make build`, `make run`, `make test`, `make coverage`, `make cli`, `make lint`.
  It points `DEVELOPER_DIR` at full Xcode, because `xcode-select` may point at
  the Command Line Tools, which lack xcodebuild and Swift Testing. For raw
  `swift`, `xcodebuild` or `swiftlint` commands, export
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (or
  Xcode.app) first.
- `make coverage` runs OTMKit's tests with coverage and uses `xcrun llvm-cov`
  to report each library source file and its total line coverage, excluding
  tests and the CLI. CI uses the same target and adds its table to the job
  summary; there is no coverage threshold yet.
- `project.yml` is the source of truth. The `.xcodeproj` is generated and
  ignored; new files under `App/Sources` are picked up by `make generate`.
- OTMKit and `otm` enable strict memory safety (Swift tools 6.2+, built with
  Swift 6.4). Keep each unavoidable C call or pointer expression marked `unsafe`
  with a comment explaining its bounds, lifetime and alignment. Owned or scoped
  pointer wrappers expose `@safe` interfaces only where those invariants hold.
  `Span` and `RawSpan`, including `Data.bytes`, work on macOS 14 with this
  toolchain; `Array.span` needs macOS 26, so do not use it for this deployment target.
  Keep the hot pointer loops below intact; annotations do not change their work.
- All tests must pass and lint must be clean (`swiftlint lint --strict`).
  Never suppress warnings or skip tests.
- A draft release carries only the commit its tag names:
  `scripts/check-release-source.sh` compares `refs/tags/vVERSION^{commit}`
  with HEAD before the build, and the remote tag's commit with HEAD just
  before `gh release create` (whose `--verify-tag` checks only that the tag
  exists). A manual draft run therefore starts from the tag.
- `make test` runs OTMKit's Swift Testing suite and `make test-app`'s hostless
  app logic tests. `OpenTaskManagerLogicTests` compiles only the stores and
  helpers listed in `project.yml`, with no application dependency, `TEST_HOST`
  or `BUNDLE_LOADER`. The project keeps XcodeGen's project presets (including
  warnings) and sets target paths explicitly to avoid its test-host preset.
  Tests inject isolated defaults suites or temporary
  folders, never the user's settings or Application Support, and pass launch
  arguments as dictionaries (`LaunchArgument.domain` is the default): the
  argument domain belongs to the whole test process, so changing it leaks
  into other tests. The bundle builds under `$TMPDIR` (`TEST_DERIVED`): run
  from ~/Documents, xcodebuild's test runner couldn't load it ("executable
  couldn't be located"). Keep pure rules in OTMKit; the app tests pin
  persistence, observation and framework wiring.

## Layout

- `Packages/OTMKit`: sampling library (System/, Model/, Monitor/, Format/,
  Graphing/ for axis and curve maths and the squarified `Treemap`;
  System/LaunchItems, BundledLaunchItems, LaunchTriggers and Launchctl read launchd
  plists and parse `launchctl` output; Model/LaunchItemSource distinguishes the
  five launchd folders, app-bundled agents and daemons, app login helpers and
  loaded jobs without a file. Bundle discovery reuses InstalledApps' application
  folders (never /System or a wider disk walk), with three directory listing
  attempts per app and no signature checks, only on opening or Refresh.
  BundleProgram resolves against the owning app; login helpers match by bundle
  ID. launchd's bulk lists supply unmatched third-party jobs (Apple's fileless
  jobs are on-demand XPC services and workers), excluding application and
  anonymous process labels. Apps reuse their already-found bundle paths;
  System/DiskUsageScanner walks a folder for the
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
  pane, `SplitMath`, the process table's columns, `ColumnFit`, and the
  Overview's per-core graphs, `CoreGrid` (core types side by side when they
  fit one line, otherwise rows of shared columns, a short last row balanced),
  the CPU page's, `CoreAreaGrid` (near-square tiles), with `CoreGraphLayout`
  capping their height by default to leave room for the summary figures, and
  Performance's main graphs' heights and figures, `HeroLayout`;
  System/NetworkQuality (parses `networkQuality -c`) and System/DiskSpeedTest (one
  unlinked temp file, F_NOCACHE reads, verified, cancellable) back the user-started
  speed tests on Performance's network and disk details (`SpeedTestStores`; nothing
  runs per tick; `-openSpeedTest start` starts the `-openResource` detail's for
  screenshots, `LaunchArgument.startsTest(on:)`) and `otm
  netquality` / `otm diskspeed`, with the last few results per interface or volume
  in Application Support/OpenTaskManager/SpeedTests (System/SpeedTestHistory);
  System/CPUBenchmark (versioned workloads in CPUBenchmarkKernels, every unit
  checked, on threads of its own, cancellable) backs the CPU detail's Benchmark
  card (`CPUBenchmarkStore`) and `otm cpubench`, the last 10 runs or sessions per Mac kept beside
  the speed tests; System/ChipLayoutReader (hw.perflevelN, device-tree clusters,
  I/O Registry core counts) backs its Chip layout card and `otm cpubench layout`;
  System/GPUBenchmark (Metal shaders from source in GPUBenchmarkKernels, timed by
  the GPU, every result checked, cancellable) backs the GPU detail's Benchmark card
  (`GPUBenchmarkStore`; debug `-gpuBenchmarkFixture nodevice|unsupported|notiming`)
  and `otm gpubench`, the last 10 runs or sessions per Mac in SpeedTests/gpu-benchmark.json;
  System/CPUSustained (the floating-point workload on every worker for 2 or 5
  min, timed in 10 s windows; Model/CPUSustainedSummary: first window, the last
  third's median, "held 97% of its starting speed", the thermal states seen,
  never a claim of throttling) backs the CPU card's sustained run
  (`CPUSustainedStore`, `CPUSustainedViews`; one CPU run at a time) and `otm
  cpubench --sustained [2|5]`, in SpeedTests/cpu-sustained.json, its own cohort;
  each new result carries an optional, versioned `context` (Model/BenchmarkContext,
  read by System/BenchmarkContextReader as the test starts: OS, app and build,
  Mac and chip, IOPowerSources, Low Power Mode, thermal state at start and end,
  the CPU's load over the few seconds before, from the app's sampler through
  `BenchmarkContextFeed` or a 1 s tick probe, and memory available); older runs
  read as "Context not recorded" and are never rewritten;
  Model/BenchmarkRun adapts those histories on read to one envelope (never
  rewritten), Model/BenchmarkComparison holds the compatibility rules and change
  against both runs' spread, with context differences as warnings that never
  refuse; `BenchmarkConditions` qualifies verdicts as Higher/Lower · conditions
  differ in amber with a short account beside them, keeping the full warnings
  below (equal heat or load alone is still comparable), and Format/BenchmarkExport
  the versioned JSON (v2) and
  Markdown, for Performance's Benchmarks workspace (`BenchmarksDetail`, `BenchmarkSections`,
  `BenchmarkWorkspace`: a selected family's compact saved-run picker before
  its results and trends, Run all through the tests' own stores, picks and ticks in
  UserDefaults, `-openBenchmarkCompare gpu:1,2`) and `otm bench`;
  Model/BenchmarkTrend splits a test's runs into lines only comparable runs
  share and gives each figure's points their spread and verdict against a
  picked baseline (beside each chart's change in a word, "within spread",
  "faster", "lower": `BenchmarkChange.verdictWord`), for the workspace's
  static Swift Charts (`BenchmarkTrendView`,
  `-openBenchmarkBaseline cpu:3`); the resource cards fold their runs into
  `SavedRunsDisclosure`, whose Compare in Benchmarks ticks the latest pair;
  System/CommandRunner runs every system tool with a timeout),
  the `otm` CLI, and Swift Testing tests. The CLI's `main.swift` keeps the
  entry point, command dispatch and usage text; `CLIOptions` parses arguments
  and `CLIOutput` holds shared output helpers. Command handlers and their
  reports live in files by family (processes, system, power, sensors, network,
  disk, apps and drivers), beside the benchmark, history and capture handlers.
  Async handlers moved from the entry point stay on the main actor. Keep pure
  logic here so it can be tested.
- `App/Sources`: `AppModel` (observable state and history), Views/Overview,
  Views/Processes (NSOutlineView table in `ProcessOutlineView`), Views/Performance,
  Views/History (the flight recorder's graphs; `FlightRecorder` in OTMKit writes
  a `HistoryRecord` every 10 s to ~/Library/Application Support/OpenTaskManager,
  and saved sessions beside them; `RecordingFile` in OTMKit is the versioned
  `.otmrecording` format, which `HistoryRecordingStore` opens into an in-memory
  recorder, and `-openRecording <path> -openPlayback 1|10|60` opens and plays one;
  events, `HistoryEvent` (app launches and quits from NSWorkspace, delivered
  process-ending signals and accepted Quit requests from OpenTaskManager, busy background
  processes from `ProcessEventTracker`, network changes, sleep and wake), go in the
  same database, its schema migrated by `PRAGMA user_version`, and in a file's
  optional `events` key; hardware series (`HistoryHardwareSample`: core-type and
  per-CPU loads, cluster clocks, the hottest dies, fans and power rails picked from
  `SensorTable`'s rows, null where unread) go in each record's `hardware` blob
  (schema 2, series named once in `hardware_series`) and a file's optional,
  separately versioned `hardware` block, charted under History's folded Hardware
  section; process history (schemas 3, 4 and 7, OTMKit's FlightRecorderProcesses
  and FlightRecorderProcessMemory):
  every process seen at two record ends or kept with figures gets a
  `process_lifetimes` row by `ProcessIdentity` (name, path,
  user, bundle ID, launchd label once Startup has read launchd's list, first and
  last seen, ended), its last sighting moved on through its run's one
  `process_watches` row, so a record writes only starts and ends;
  `ProcessHistoryTracker` holds a new idle start one record, keeping its
  original first-seen time and any launchd label, and writes it at the next
  end if still running or kept with figures. One that ended in between with
  no kept figures, or started and ended within a record, is only counted, one
  row per record and kind (`process_kinds`: name, path, user) in
  `process_short_runs`, and the app's own such children (ps, nettop,
  launchctl) not at all;
  a sampling gap or no longer watching a restricted process never turns a
  deferred lifetime into a confirmed short run;
  `ProcessHistoryTracker` takes native CPU and disk from the cumulative
  counters the sampler already reads; restricted CPU integrates the held
  rates between `ps` reads, so record boundaries never invent idle time, and
  `ProcessHistoryKeep` keeps figures only for the 5 largest footprints, busy disk
  and CPU users, 40 at most, so a missing row while it ran is "idle, not stored",
  never zero, and a stretch without records a gap. Schema 7 also keeps
  coarse memory for every stored lifetime, including idle ones, in
  `process_memory` (WITHOUT ROWID, lifetime and time as its key): first and
  final readings, changes of at least max(10%, 16 MB) from the last step,
  or any change after 30 min. `ProcessMemoryKeep` and `ProcessMemoryState`
  are pure rules in Model/ProcessMemoryHistory. Native footprint and ps RSS
  carry their measures; a changed measure or stopped watch closes one line
  and starts another, never joining the two. A lifetime's peak, time and
  measure are updated only when a larger reading is observed (a changed
  measure starts its own peak). Threshold steps include spikes between
  record ends, while peaks are written once per record. The state lives
  inside the tracker's existing counter entries; all changed steps share
  one buffer, with no per-process arrays or added process reads. Pruning
  clips one held anchor at the seven-day boundary and deletes older steps
  and orphaned tracks. A watch marks that it keeps memory, so records from
  older builds never extend a held memory figure. History's Processes section
  (`HistoryProcessStore`, `HistoryProcessSection`) searches lifetimes by name,
  path, label or PID, sorts by Latest or Grew (last minus first retained
  memory, computed in SQL before limiting results), and charts one, marked on the rail and in the moment panel,
  and lists short runs by name or path ("83 short runs between …", over records
  that follow on, no PIDs, nothing to chart),
  the process inspector's Show History opens it, `-openProcessHistory <query>`
  searches it and picks the latest match, and `otm history processes <query>`
  prints each lifetime's first, peak and last memory reading, with steps in
  `--json`. The selected lifetime also shows How it ended (`ProcessEnding`):
  independent diagnostic reports, app-ending actions and launchd exits, each
  with its own time. `ProcessDiagnosticReports` lists each readable user and
  system DiagnosticReports folder once, filters names and modification times,
  reads at most 256 KB per candidate .ips, and decodes only the identity and
  exception or termination fields. Jetsam lists need a matching PID and name
  with a reported killing reason; merely being in the list proves no exit.
  A known path must match when the report supplies it; absent paths use the
  name. Report times must fall from the process start through 120 s after its
  observed end or last sighting. Unknown bug types stay Diagnostic report;
  hang reports never claim a crash. Show Report reveals the file in Finder.
  Delivered signals and accepted Quit requests are `.endedByApp` events with
  identity, executable path and signal in their JSON detail; schema 9's event
  index keeps same-named group targets separately. Quit requests and SIGTERM
  deliveries keep their wording, since neither proves that it caused an exit.
  New observed launchd ends keep the exited identity; replacements never
  attribute their code to a lifetime. Older job history needs a preceding
  running PID in the same domain, with the exit observation near the end.
  An ended lifetime keeps its actual last sighting separately from the end
  observation; older rows remain readable with their former end-time sighting.
  With no evidence it says Ended between the two times, with no crash report
  or exit status found, never a cause inferred from disappearance. The CLI
  prints the same evidence as `ended:` lines and an `ending` JSON object.
  Report and ending lookups run on the recorder actor only on selection (or
  in the CLI), cached across graph refreshes, never at record time or per tick.
  Running processes show no ending block;
  recording files carry no process history yet, so their Processes
  section is a compact notice with Search Live History, which closes the file
  and focuses the live search. Idle-only results with a memory track show a
  static step chart and "Memory only: changes of 10% or 16 MB, CPU and disk
  stayed under the history's floors"; older lifetimes without memory still
  show "Idle throughout: no busy figures kept" without empty charts.
  A busy lifetime overlays the step track between its kept memory figures.
  Memory is loaded with the selected lifetime, never per tick. Exact
  recorded stretches and step edges bound the track and the moment panel:
  "Footprint about 412 MB (from the memory track)" (Resident for ps RSS),
  "Idle (not kept)" only for a watched idle point without memory, and
  "Not recorded" for real gaps (`ProcessHistoryLabels` in OTMKit). At Latest, a running lifetime may show
  its latest kept memory for at most one actual record span past the last recorded stretch, with
  the kept reading's original time and "the latest record", never a newer or extrapolated value.
  Ended lifetimes and stopped watches cannot borrow that reading. The memory chart has one key:
  dashed "Memory kept while idle", solid "Busy figures" when present, and the shared hatched
  "Not recorded" look. Idle stretches carry no repeated memory labels. Compare's figures, `HistoryIntervalStats` and
  `HistoryComparison`, leave gaps out, and Layout/CompareBrackets places its A
  and B brackets over the rail; each interval's column heading gives how much
  of it was recorded, and `HistoryComparison.limitation` (a side under
  `lowCoverage`, or under `unevenCoverage` of the other's share) puts a notice
  over the figures, with Compare Recorded Overlap when `recordedOverlap()`
  finds a minute or more both recorded at the same offsets (one-step holes
  bridged), which narrows A and B to it until Back to Full Stretches;
  `-openHistoryCompare <minutesAgoA>,<lengthA>[,<minutesAgoB>,<lengthB>]`
  opens Compare with them picked, counted back from the range's end, with B the
  same length before A when left out; Compare's Change column is headed "A vs B"
  (points for shares, degrees for temperatures, else relative to B), with
  spoken "A is … higher/lower than B" labels (`HistoryComparison.Change`,
  wording in `HistoryCompareLabels`). Under
  900 window points its interval and coverage headings shorten, the headline
  grid shows averages, and notices keep their full explanations in help;
  the wide layout keeps its wording and figures. A side under 90% recorded,
  or shares differing by more than 15 points, also puts both recorded shares
  and the changes' recorded-time scope under the headline figures
  (`HistoryCompareLabels.recordedScope`). The pinned rail folds to a strip (the
  section at the top, the span, the moment, Play and speed, a slim track that
  marks spike events) once the charts' top has scrolled under it; hovering a
  gap in either rail shows its span and possible causes (`HistoryGapLabels`).
  The rail comes back whole at the top or from the strip's button: `RailFold` in OTMKit's Layout/ holds the rule, and
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
  length, so it buckets by the second; spike replays open at the first trigger's
  time (`SpikeReplay` in OTMKit), including `-openRecording` and playback started
  with `-openPlayback`. Below 900 window points the recording banner keeps its
  title, trigger time and actions, and moves the machine, record count and
  unreported figures to Details. Both widths show a Read-only badge
  (`HistoryReplayLabels` in OTMKit). The moment panel's event descriptions
  wrap to two lines in their own column, beside a trailing column of complete
  relative times. The banner's Jump to Spike pauses there from anywhere,
  with every trigger's time in its help. Every time chart marks the triggers
  with the rail's bolt and a thin rule, laid out once without reading the
  scrubber (`HistorySpikeChartMarks`); ordinary recordings still open at the end.
  A `-sensorFixture` run captures nothing;
  `-captureSpikeNow cpu|memory|thermal|disk|network` (debug builds) forces one 15
  updates in, `-openSpikes YES` opens the list, `otm captures [--json]` lists them),
  Views/Connections (socket table; `ConnectionStore` runs the walk; Show
  Hidden… beside the hidden-process count, and Show Hidden Sockets… in its
  popover, read every process's sockets once as root: `PrivilegedSocketReader`
  runs lsof through osascript's administrator prompt, off the main actor, and
  `PrivilegedSocketRead` turns its fields into `Connection`s with their
  account, for `HiddenSocketsSheet` (other accounts by default, or everyone,
  with the page's counts). It is a snapshot: only Read Again reads again,
  nothing is installed and nothing keeps running as root; a cancelled prompt
  with nothing read closes the sheet),
  System/OwnerLookup and OwnerQuery reverse that lookup for a file (device and
  inode), folder or volume (open paths and current directories), or local TCP/UDP
  port. ProcessDescriptorReader shares the libproc buffers with ProcessInspector
  and ConnectionSampler. Processes' View menu has Find Owner… (⇧⌘F), whose
  FindOwnerSheet accepts text, a Finder drop or Choose… and selects a result by
  ProcessIdentity. `otm owner <path|port> [--json]` prints the same matches,
  coverage counts and walk time. Unreadable processes stay counted even when a
  process has a partial match; an empty result names what was checked. Volumes
  mention that Spotlight or the kernel may also prevent ejecting,
  listener reviews (schema 8, `FlightRecorderListeners`): `listener_review`
  keeps the reviewed baseline and pending changes independently of history retention,
  even with recording off. `ListenerIdentityReader` reads signing team and identifier
  once per executable path, without validation. Identity is path and signature,
  TCP/UDP, port and bind scope (loopback, all interfaces or a specific address),
  never PID or descriptor; a port in the system-assigned range (49152–65535) counts
  as one per executable, so a random port at each launch isn't a new listener. `ListenerChangeRules` and `ListenerDebounce` in OTMKit
  compare only identities seen on two consecutive walks; gaps restart the pair.
  New executables, new ports, widened loopback binds, changed addresses and ports
  held by another reviewed executable stay pending until Accept or Accept All adds
  them to the baseline. The first walk seeds it without changes; unreadable
  processes and paths are counted as unknown, never absent listeners.
  The Connections summary's Listeners entry opens the review and each retained
  observation's socket details. `otm ports --listeners --changes [--json]` reads
  the saved review and compares two walks without creating or changing a baseline;
  socket history (schema 6, `FlightRecorderConnections`): `connection_lifetimes`
  keeps one row per observed segment from `ConnectionWatch`, with process identity,
  executable path and user, endpoints, the TCP states seen and its bounded timeline.
  A confirmed end says closed between the last sighting and the next walk; stopping
  a watch or reopening an unfinished row says still open when watching stopped,
  never inventing a close time. `ConnectionHistoryTracker` writes starts and ends,
  with long-lived rows bumped at most once a minute. A row not seen closing keeps
  `open_key` (`Connection.historyKey`: PID, process start, descriptor, protocol,
  kernel handle); the first walk after a start, a stop or a coverage gap looks
  those up once, and the same socket with the same peer carries on in its row with
  an unwatched step, so page visits and relaunches don't repeat a long-lived
  socket. Changing cadence starts a coverage interval while sockets
  already followed by the shared watch keep their lifetime. `connection_coverage` keeps real watched intervals,
  their walk spacing and unreadable-process counts. Gaps over twice that spacing
  break coverage; an absent socket outside it means not watched, never no connection.
  These tables are pruned with the recorder after 7 days, coverage clipped at the
  cutoff; 50,000 lifetimes at most, oldest ended rows dropped first, with losses
  counted in `connection_limits` and named in the coverage line. Connections' History
  list loads on opening, search and interval change, never per walk, with Last hour,
  Today and 7 days. Search text is filtered in SQLite before timelines are decoded,
  and coverage and rows come from one database snapshot. It shares the details
  pane and opens live History at a stored
  observation through Show in History. `otm connections history [TEXT] [--since
  1h|24h|7d] [--json]` reads lifetimes and coverage without sampling or migration;
  launch job history (schema 5, `FlightRecorderLaunchJobs` and
  `FlightRecorderLaunchState`): `launch_job_events` keeps observed transitions
  by label and launchd domain; `launch_job_state` keeps the last changed state,
  seeded once on the first read at each launch, and is upserted only on a state
  change. An unchanged job writes no event at relaunch or after sleep.
  `launch_job_reads` keeps coverage once per domain: consecutive successful reads
  within 90 s extend one interval's end; a new app run, a longer interval, or a
  failed or missing domain starts a new interval. No job carries gap events.
  Events and coverage are pruned after 7 days, outside `.otmrecording` files;
  coverage crossing the cutoff is clipped. A loaded job's one baseline survives
  however old its last change is, while old unloaded baselines can age out.
  `LaunchHistoryDerivation` and `LaunchHistoryTracker` distinguish watched
  transitions from changed states while unwatched, bounded by `since`, never
  inventing starts, exits or restarts across a hole. Configuration reads retain
  path, modification date, program and arguments. `LaunchHistoryPattern` gives
  a cadence only when domain coverage spans the first counted failure through
  the verdict's read time, and explains only known exits. `StartupHistorySection`
  loads events and coverage together on opening or Refresh, after the page write;
  its static 24-hour lane strengthens watched stretches over the faint unwatched
  line, keeps event marks, and captions how much of the day was watched.
  `StartupFilesSection` checks the current plist and executable on opening or
  Refresh, including `CodeSigning.validity` (contents validated on demand, not
  notarization) and at most 20 log lines from a bounded tail. `LaunchJobFiles`
  refuses protected paths and links into them before touching their targets,
  reads only local regular files, and reports unavailable files as Not readable.
  `otm startup [--source NAME] [--json]` lists the inventory with SOURCE,
  accepting LaunchItemSource's raw names or visible titles; JSON retains the
  existing item fields and adds source and owningAppPath. The Startup Source
  menu wraps below the existing filter in a narrow window. Its details show
  Source under Kind and reveal a plist or login helper. Bundled and fileless
  jobs cannot be controlled here: their app or macOS owns registration.
  Start at login counts enabled agents with RunAtLoad/KeepAlive and helpers
  launchd lists, excluding boot daemons and unlisted helpers. App-bundled files
  show shipped items, not proof of approval: Open at Login apps require Apple
  Events or admin rights, and Background Task Management approval switches
  require admin rights. The Settings button remains the way to inspect them.
  `otm startup history LABEL [--json]` reads stored events in both domains without
  sampling or modifying the database, printing coverage before events; its JSON
  is an object with `coverage` and `events`. `LaunchExitStatus` encodes only a
  flat `{code: integer}` or `{reason: string}` object, including the `lastExit`
  fields under `otm apps --json`, and refuses synthesized enum payloads;
  Views/Startup (launchd items in a SwiftUI `Table`, scanned off the main actor
  when the page opens and on Refresh, never per tick; while it's on screen
  launchd's list alone, no plists, is read again every 10 s and noted in
  `LaunchJobStore`, whose `LaunchJobWatch` in OTMKit counts restarts by label,
  scope, PID and start time and names failed, crashed and restarting jobs for
  the Problems filter; `LaunchItemStatus` in OTMKit is the one label for what
  a job is doing (Running, Restarting, Crashed, Failed · exit code 1, Not
  running, Disabled, Not loaded). The Status column stays short ("exit 1"
  where narrow); its failure tooltip names when that exit was first seen,
  or "time not known". The details say "Not running · last exit code 1 at …",
  naming the date too before today, from the retained matching job baseline,
  never an exact exit time or the latest unchanged read. Problems still
  includes it. LaunchJobStore publishes the recorder's already-held baselines
  after page writes, without another per-job query. View history beside Last
  exit scrolls to the existing History section. Apps shares the short status;
  launchd's Loaded or Not loaded stays on a line of its own; the details put Program right under it, and a notice
  (`LaunchJobHealth.notice`) only where it adds something: what a known code
  or a crash signal means, a failure before the run now, restarts seen; the CPU and Memory cells look launchd's PID up in the
  latest sample themselves, so a tick redraws them, not the table),
  Views/Apps (installed apps in a SwiftUI `Table`; `InstalledAppStore` scans off
  the main actor when the page opens and on Refresh, then streams bundle sizes in
  from a few GCD threads, and follows launches and quits through NSWorkspace,
  never per tick),
  Views/Users (per-user totals; `UserUsageStore` builds sorted display totals
  only on screen, keeping just CPU and memory sums for continuous histories
  otherwise; the grouping is `UserUsageBuilder` in OTMKit),
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
  in OTMKit's System/Extensions, SystemExtensionList and KernelExtensionList;
  System/ExtensionBundles reads the `.kext`, `.systemextension` and `.dext`
  copies one level into /Library/Extensions and the Applications folders, never
  /System, and Model/ExtensionMatching ties each to what's registered or loaded
  by identifier and version, the rest being rows "Installed, not in use" or,
  when that can't be told, "Unknown"; vendor (All by default, each segment
  with its count; third party sorts first either way) and Status (All, Loaded,
  Not in use) filters combine, and summary cards toggle the rows behind their
  count with an accent outline while selected. A card whose count takes in
  Apple's too widens a narrower vendor to All, and deselecting it puts the
  vendor back (`DriversStatusFilter` and `DriverSummaryFilter` in OTMKit);
  tests use fake bundles in a temp dir),
  Views/Storage (disk space: before a scan, `StorageCapacityPanel` shows each
  local volume's used, purgeable and free space over the places to scan,
  `VolumeCapacity` in OTMKit splitting `VolumeInfo`'s capacity by its
  important-use and plain free figures, read when the page opens; purgeable
  counts as available, as in Finder; `StorageStore` keeps the session's last scan and
  scans on Scan, a scope pick, or an opt-in schedule while the app is running,
  never per tick; the treemap
  is laid out once per scan, folder and size, drawn in a `Canvas`, and its hover
  layer and the fixed-height strip below it read the pointer; the strip names
  the hovered item, else the selection, with its path below the scan root,
  size and share. A click selects and brings its folder-list row into view;
  double-click or Return opens a folder. Arrow keys follow tile geometry
  (`TreemapNavigation` in OTMKit), including tiny tiles and drawn children;
  each region has a spoken name and size. Each finished scan's summary is saved once, off
  the main actor, to Application Support/OpenTaskManager/Scans, and the Changes
  list colours the treemap by what changed since an earlier scan; the change
  picked there is named above the map, not in a tag over it (`PickedChangeBar`:
  its trail with the outlined folder underlined, why the map can only outline
  what holds it, `TreemapReach` in OTMKit, then Open, which keeps Changes, and
  Reveal in Finder); "Where the space is" (`StorageReconcilePanel`), folded at
  first, reads the volume's figures once per finished scan, off the main actor.
  Unfolded, its existing scroll view is capped at 180 points and at the space
  left after the top cards and treemap. StorageResultsLayout reserves at least
  180 points for the map itself, plus its breadcrumb, selection and caption,
  so reconciliation scrolls inside the panel and the status strips stay visible.
  Very tall top cards or a shorter window scroll the results as well, keeping
  the schedule strip inside the window. Measurements change with content or
  window size, never sampler ticks.
  Largest Files supports Cmd/Shift selection by path; a treemap item's Add to
  Cleanup joins it. Clean Up opens `StorageCleanupSheet` only after
  `StorageCleanupReader` has refreshed the picks off the main actor. The scan
  keeps volume and file identities with its bounded results. `StorageCleanupRules`
  collapses picked descendants and flags changed, unowned, private, cloud and
  remote items, leaving warnings unticked. Home and its standard folders,
  mount points (or their parents), symbolic links, missing or unidentified
  items and read-only volumes are never offered. Folder measurement is bounded
  at 20,000 entries; unknown totals say "at least", never zero as a measurement.
  `StorageCleanupExecution` rechecks each item immediately before the app's
  `NSWorkspace.recycle` adapter moves it, reports each result and separately
  measures the volume's available capacity before and after. Rescan is offered,
  never automatic. A new scan clears cleanup selection; nothing runs per tick),
  Components/Graphs (graphs, bars, cards), and Support (icons, hot key, menu bar icon).

History’s Investigate action opens a fixed incident window (±2 minutes by default,
with ±1/2/5/15 choices or the marked/compare interval unchanged). `IncidentTimeline`
and `FlightRecorderIncident` gather resource/baseline summaries, process starts and
ends, launchd transitions by domain, socket changes, pending listener reviews and
events in one actor transaction. Schema 10 adds indexed process start/end, watch
and socket start/closure queries. Each lane and coverage query is capped at 200
rows with explicit cut notices; ending evidence loads for at most 20 lifetimes.
Only exact recorded process identities link lanes. Each lane's coverage is a strip
in History's track look (`IncidentCoverageStrip`), its exact spans in the help;
records within History's gap spacing (2.5 record spans) count as one watched
stretch. Resource figures and the five busiest above zero keep their order and
show no time, since they sum up the window. A ±N window opens on its own choice;
"Picked range" appears only for a marked or Compare interval. Happened together sequences
state observations, never causes. Incident exports choose Markdown or JSON in
NSSavePanel, redacting home paths, user names and remote addresses (/24 or /48)
by default. Accepted listener changes are not a historical audit log. Event observer coverage
is not independently persisted; the event lane labels recording spans and event
sightings as inferred coverage rather than claiming continuous observation.
`-openIncident <ISO8601|latest>` opens the sheet on History; debug-only
`-incidentFixture YES` uses made-up values, disables the persistent recorder and
spike captures, and leaves automatic storage schedules stopped.
`otm incident --at <ISO8601> [--minutes N (1–15)] [--json]` reads without migration.
The incident sheet queries only on a window change, never on a timer or tick.

## Performance rules (the app must stay light)

- Find Owner runs exactly one bounded descriptor walk per search, off the main
  actor, with no timers, per-tick reads or sampler observation. Path resolution
  reads the query once; file matches use the vnode's device and inode, never a
  path string or per-descriptor stat. Port searches read only socket descriptors.

- `StorageScheduler` has one one-shot timer for the earliest due scope, none
  without schedules. Due but ineligible work retries every 15 min and on wake;
  power/thermal change notifications also move this same timer forward.
  No scheduler work runs on sampler ticks. HID idle time, IOPowerSources, Low
  Power Mode and thermal state are read only at a timer firing. Run Now
  queues work on that same timer and still respects every safety condition.
  Each refusal stores its reason and check time in the schedule's optional
  lastRefusal, including scope access failures; older schedules still decode.
  Due schedules show these in the page's popover with Run Now, or the default
  two-minute idle rule and "Last checked: not recorded" before a refusal exists.
  A scan starts only after 2 min without input, with battery at least 30%,
  Low Power Mode off and thermal state below serious. Automatic walks use
  utility QoS, share the manual scanner and archive, and keep the scan slot
  through cancellation and summary saving. Power and thermal notifications
  stop an active automatic walk if its conditions become unsafe. No launch
  agent or helper exists.

- Slow sources follow visible demand, counted across windows by
  `SamplingDemandStore` and `SamplingDemand` in OTMKit. `SamplingDemandLease`
  keeps each view's count balanced across repeated visibility notices. A demand
  view releases
  its count when removed, scrolled out, minimized or occluded. The Overview's
  CPU and Power cards, Performance's Thermals rail row or chip, and the Thermals
  detail need sensors each tick; otherwise `SensorMonitor` reads every 5 s.
  Processes, its inspector and Users need `ps`'s CPU and memory walk each
  tick; otherwise it runs every 5 s after two initial reads establish CPU
  rates. Its thread walk (`ps -M`, a line per thread) stays at most every 5 s.
  `RestrictedProcessCache` holds rows by PID and start time
  and computes CPU over the real interval between reads, never the app tick.
  While any content window is visible, the native process list, CPU, memory,
  disks, network, GPU and power stay live. `SamplingDemand.window` counts the
  main window, Settings and the menu popup, never the status icon or the mini
  monitor. Application
  hiding, display sleep and screen lock override the count; showing a window
  interrupts the sampler's wait and takes a fresh sample.
- Media-engine active time (`MediaEngineSample`, GPU detail and History's Media
  engines chart) comes from PMP0 / SOC Floor: VMIN is the minimum state; VNOM,
  VMAX and VOVD count above it. This is power-state residency, never utilization
  or throughput. Only known media domains and valid advancing counters become
  readings; the M5 Pro's PRORES channel stayed all-zero even during a hardware
  ProRes encode, so it is omitted. A separate IOReport subscription polls at
  most every 2 s while `.mediaEngines` demand is visible, otherwise 5 s, from
  the existing sampling loop. Cached values feed the card, while
  `mediaEnginesFresh` / `freshMediaOnly` keep held values out of History and
  sensor ranges. History stores `.media` series using its existing metadata
  and hardware blob. Debug `-mediaEngineReplay <small JSON array>` replays
  captured samples in the GPU card only, labeled Recorded example; it changes
  no recorder data.
- The optional Dock graph (`DockIconController`, `Settings.dockGraphMode`) uses
  the same `record()` system samples while hidden, with no timer or window demand.
  `DockGraphFeed` keeps sixty two-second slots, including gaps after pauses and
  slower sampling, and quantizes into bitmap pixels. It draws at most every 2 s,
  skips identical images and display sleep, and marks paused readings. Off
  restores the normal Dock icon. A live Dock graph keeps the app running after
  its main window closes; the Dock reopens that window.
- The floating mini monitor (`MiniMonitorController`, `Settings.miniMonitor*`)
  is a nonactivating `NSPanel` above windows, among them or on the desktop. Its
  demand is `SamplingDemand.miniMonitor`, so shown on its own it keeps the
  background pace above. `record()` feeds `MiniMonitorStore` every tick while
  it's on; `MiniMonitorFeed` in OTMKit averages ticks into points of the update
  speed, never under 1 s, so a visible window's half-second ticks and hidden
  1 s ticks make the same graphs. The store publishes only while the panel is
  on screen and the display awake. Its figures are plain text and its graphs
  don't stream: nothing in it moves between points.
- With no visible content window, `BackgroundSamplingPolicy` in OTMKit keeps
  a system feed at the chosen update speed, never faster than 1 s, so a hidden
  window never samples more often than a visible one: `HistoryAccumulator`
  averages ticks and keeps their CPU peak, not just cumulative counters every
  10 s. Its top-app memory lists keep the highest sampled footprint, so native
  rusage figures and the kernel process list keep the same step. The latter keeps observed lifetimes and short
  runs correct; `ProcessHistoryTracker` takes native CPU and disk from cumulative
  counters and integrates restricted CPU between ps reads. Its coarse memory
  steps reuse those same native footprints and held ps RSS readings; the
  sampler adds no per-process calls, and History publishes nothing new per
  tick. Memory peaks stay in value state between records. Hidden sampling
  skips `PROC_PIDTASKINFO`, `ps -M` and the per-process GPU walk. With spike
  capture off, ps stays at 5 s after priming; with it on, ps reads each second
  for the capture's top processes. Spikes cap a slower visible update speed at
  1 s. System GPU and component power still feed the flight recorder.
- Hidden ticks update `BackgroundSamplingState`, not observable snapshots,
  process/group/user graph rings, sensor rows or published ranges. Raw sensor
  ranges continue in the unobserved state. A bounded ring keeps real system ticks for resume, and the separate icon ring keeps consecutive
  CPU points for its 2 s drawing limit (no icon publication while asleep or locked).
  At the same graph cadence, resume appends those retained ticks; process and user graphs restart with the
  unrecorded look. A changed cadence or sleep gap restarts system graphs too,
  never stretching a held figure into invented points. Energy and peak power
  keep measured hidden ticks without publishing them. View-only nettop, sockets,
  inspector files, user sessions and live History refreshes wait on
  visibility notifications while hidden, rather than polling their sources.
  Launch job history and opt-in socket history are inventory exceptions. Settings'
  History switch, Keep watching connections in the background (`backgroundConnections`,
  off by default), schedules sockets at most once a minute while recording and the
  page isn't visible, on the same `ConnectionStore.shared` watch, off the main actor.
  No new timer or per-tick descriptor work is added. Listener review uses these
  same walks, off the main actor, publishing only changed review state and counts.
  Settings' `listenerChangeNotifications` switch defaults off and requests permission
  only when turned on; with background watching enabled it posts one notification
  for a walk's new batch, never again for unchanged pending changes.
  Background walks publish no
  table rows, and page reads move the shared deadline on. The ConnectionHistory debug
  category logs wall and thread CPU seconds for each walk; a headless `otm ports`
  with `OTM_CONNECTION_WALK_TIMING=1` prints that measurement to stderr.
  While the recorder is on, launch job history uses
  the existing sampling wakeups to schedule one bulk snapshot a minute, off the
  main actor, reading no plists and printing no individual job. `LaunchJobStore`
  shares its deadline with Startup's existing reads; those reads supply the
  recorder too. Each bulk snapshot uses a fixed pair of commands (`launchctl list`
  for this session, `launchctl print system` for daemons), independent of job
  count. Failed domains break observation coverage rather than unloading jobs.
  Debug logs in the LaunchJobHistory category give wall seconds per bulk read;
  background reads never publish view state. Fixture runs keep no job history.
- `MenuBarLabel` observes only `MenuBarIconStore.drawing`, never the snapshot
  or full CPU history. OTMKit's `MenuBarDrawing` compares the last 14 bars at
  half-point resolution and the rounded text. The icon alone publishes changes
  at most once every 2 s (or the chosen slower update speed), with the newest
  sample and consecutive graph points. Identical pixels publish nothing;
  `MenuBarIcon` also reuses the same image. No extra setting is needed.
- Keep process, app-group, user, sensor and hardware histories continuous when
  their page is hidden but another content window is visible. Sensor readings
  are held between slow reads, appended each tick and included in every 10 s hardware record; this adds no HID reads.
  App-group histories still append every tick because by-app and inspector
  graphs and the recorder need the groups as they stood then. Sensor ranges
  also keep every tick's clocks and power, but table sorting and row publication
  wait for the Thermals detail. Hidden Users keeps only CPU and memory sums,
  leaving its full display totals and name sorting until it is visible.
- Don't attach SwiftUI `.animation` or `.contentTransition` to values that
  change every tick. Each animation frame re-runs layout for the whole window;
  on the Overview page this cost about 75% of a core. Animate with Core
  Animation layers instead (see `StreamGraphView` and `CardSurfaceView`). Keep
  continuous motion to the rate its device-pixel travel needs, since render
  server frames cost CPU too.
- No blur filters or `.shadow` on views that redraw every tick. Fake the glow
  with wide translucent strokes, or use CALayer shadows with a `shadowPath`.
- The process table updates rows in place: `OrderedDiff` moves, inserts and
  removes rows, and visible cells are restyled. Don't go back to calling
  `reloadData()` every tick. It sorts by each figure as shown (`ShownFigure`),
  so rows that read the same don't swap every tick: they go by memory as shown,
  then PID.
- The Thermals table (`SensorTableView`) is AppKit rows made only when the set
  of rows changes; a tick sets just the figures that changed. Its rows and
  ranges are `SensorTable` and `SensorExtremes` in OTMKit. Its header (the
  since line, Reset and the column titles) pins to the page's visible top by
  watching the enclosing clip view's bounds (`StickyHeader` in OTMKit), so it
  moves only on scroll, never per tick; rows are added below it.
- Graphs go through `GraphView` (`StreamGraph.swift`): paths are rebuilt once
  per sample and `StreamGraphMotion` moves the scroller and head markers with
  actions disabled between samples. `WindowAnimationClock` shares one display
  link per visible window with counting numbers, batches equal-rate clients
  under one cached deadline, and moves all due batches in one transaction even
  on fixed-refresh displays. Rates, batch membership and the link's rate are
  refreshed between frames on samples or display changes, never per frame;
  finishing clients are removed after the frame. The clock compares batch
  deadlines, then walks only due clients and their prepared marker curves over
  buffer pointers, with no view or visibility queries, dictionaries or array
  copies. Scroll, window and accessibility notifications handle visibility and
  Reduce Motion; the link stops when idle or occluded. Graph frames allocate
  no work arrays; counting numbers still format and compose glyphs only when
  due, with their existing glyph-cache allocations and view reads. Rate maths
  lives in OTMKit's `GraphMotion`: about one device pixel per frame, 4–60 fps,
  capped by the screen, including a head marker's vertical curve speed. The
  scroller is rasterized; line bloom is a wide translucent stroke, and the
  marker, axis labels and card halo have explicit shadow paths. An
  update without a new sample (pages redraw a few milliseconds after a tick)
  draws nothing and never cuts a scroll short: that made Performance's details
  and the inspector step a sample at a time while their sidebars glided. Changing
  numbers go through `AnimatedNumber`, which composes cached glyph bitmaps at
  up to 30 fps only during a visible change, settling after 0.6 s. Changes that
  format to the same text need no counting frames; unchanged card glow never
  restarts its 0.6 s ease.
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
  `RunningSum`, never re-summed; a graph reads one ring per app), `AppModel.shortGraphSpan` on Overview,
  which always fits its window to what's been collected until it fills, in steps
  of 10, 20, 30 and 45 s, then 1, 1.5 and 2 min (`GraphCoverage.shortFittedCapacity`),
  so readings fill most of each graph from the start. The Overview's cards are
  mostly their graphs (`OverviewGraphCard`: a headline, a key whose marks draw
  each line as it's stroked, the graph across the card) and its Cores card a
  small graph per logical CPU (`CoreGraphsCard`). Top lists (`TopAppsCard`) skip figures that read as zero and hold
  their room for 30 s (`TopListRoom` in OTMKit), so the page doesn't jump;
  the idle line under the rows is a footer shorter than a row
  (`TopListRoom.height`), so a sparse list alone in its row stays compact,
  and the room grows only for rows two samples in a row list, so an app busy
  for one sample gets neither a row nor 30 s of empty room. The card tells
  samples apart by `AppModel.appGroupsUptime`, which isn't observed: reading
  `snapshot` there too drew the Overview's cards about twice a tick.
  Performance's Fit collected data toggle (`GraphFit`, on by default, in the
  main graph's time axis until the window is nearly full) narrows that one window, through
  the `graphWindow` environment value, in steps (`GraphCoverage.fittedCapacity`),
  never per tick, so the graphs keep scrolling. Squeeze older time
  (`squeezesOlderTime`, off by default, a checkbox in the same axis) keeps
  that window in the right 60% of each main graph and squeezes 15 windows
  (75 min at 1 s) into the rest, harder the older they are (`TimeWarp` in
  OTMKit's Graphing/: 1–3 windows back in 18%, 3–7 in 12%, 7–15 in 10%), ruled
  and labelled by `SqueezedTimeAxis`; Fit is off while it's on, and the CPU
  page's graph per core isn't squeezed. `AppModel.olderTime` (`LongHistories`
  in Monitor/: 10-sample buckets of mean and peak, unobserved) takes every
  tick, shown or hidden, only while it's on, a hidden tick weighted by its
  interval; a sleep gap adds unrecorded buckets and a cadence change starts
  it again. `SqueezedTrace` merges buckets to a column per device pixel, the
  peaks a faint band over the means, and `StreamGraphOlderTime` draws them in
  a rasterized layer left of the scroller, redrawn only when a bucket closes
  (about every 10 s), never per frame. In a debug build `-olderTimeFixture YES`
  fills it with a made-up hour, ten minutes asleep, for screenshots. A reading a Mac never gives
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
  `ScrollSpy.nearestHeader` chooses the group whose first header is nearest
  the visible top, including after a jump stops short at the page's end;
  no timed hold pins the last click. Only the jump bar reads that group.
  The bar is in-page links, not tabs: "Jump to" and a link per group, the one
  at the top underlined (a menu when narrow). A search marks its finds in the
  cards' titles, labels and values (`SearchMarks`, ranges from
  `SystemReportSearch.highlights`, which folds as the matching does), outlines
  the match gone to, and puts Clear Search beside its count.
- The Connections page's socket walk (`ConnectionSampler`, every process's
  descriptors) is too heavy for the main sampler's tick. `ConnectionStore`
  runs it off the main actor every 3 s while the page is on screen. Opt-in
  background walks run at most once a minute while recording; the same watch
  feeds both and SQLite writes are batched per walk on the recorder actor.
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

- CPU benchmark inputs are immutable Sendable values. Each worker and its
  borrowed pointers stay on one thread inside `BenchmarkKernel.withWorker`;
  scratch allocation and pointer borrowing happen before that worker's timer.
  Keep the versioned units' pointer loops unchanged, with no locks, atomics,
  allocations or added indirection in them.
- History observer tokens and the network monitor's CF store stay inside
  `OSAllocatedUnfairLock` scopes, including cleanup. These handles are not
  Sendable, so the lock uses `uncheckedState`; its checked `withLock` prevents
  them from escaping. The network callback retains a weak context rather
  than an unretained monitor, so queued callbacks cannot outlive their target.

GPU benchmark workload protocol v2 times fill as pixels blended divided by the interval
from the first render pass's vertex start to the last pass's fragment end. It measures
render passes only: no resolves, stores into other targets, or command-buffer scheduling.
On GPUs with stage-boundary sampling and the common timestamp counter set, one shared
two-slot sample buffer is allocated for the run's fill runner and reused after completion.
Each submission is bracketed by Metal CPU/GPU timestamp pairs; counter ticks are converted
using that submission's clock slope. Resolution and output verification happen after timing,
separately. Missing, error or non-monotonic counters fall back to command-buffer GPU time
and qualify the figure; they never prevent a supported workload from finishing. No counter
allocation, reads or polling occur outside a user-started benchmark.

Each timed repeat saves optional `GPUTimingEvidence`: render-pass, command-buffer and wall
intervals. Fill timing is verified only when every repeat's counter interval is inside its
command-buffer interval within 1 ms, and command-buffer time is not short of wall time by
the existing 5% and 5 ms rule. Repeat spread remains separate; comparisons still use both
runs' spread overlap. Qualified fill figures keep the Timing unverified badge and are left
out of faster/slower verdicts, with “Fill rate left out: timing not verified on this GPU”.
The CLI prints timing sources and verdicts; JSON carries the evidence. Saved v1 results
still decode with their timing caveat and never compare with v2 results.

## Screenshots and UI checks

Never click or script the UI while the user is at the machine, and never bring
the app to the front. Launch it in the background, then capture its window by ID:

```sh
open -g -n .build/xcode/Build/Products/Debug/OpenTaskManager.app --args -openPage Overview
screencapture -x -o -l <windowID> out.png
```

`-openPage Overview|Processes|Performance|History|Connections|Startup|Apps|Users|System|Drivers|Storage` sets the starting page, and
`-openResource cpu|memory|gpu|disk|network|power|sensors|benchmarks` the Performance detail
(`-openScroll bottom` starts the page scrolled to the end, and Startup's
details at their History and Files), `-openProcess <pid>`
selects a process so its inspector shows, `-openFindOwner <path or port>`
starts on Processes and opens Find Owner with that query searched, `-openProcessHistory <query>` (with
`-openPage History`) searches History's Processes section and charts the latest
match, `-openConnection <port or text>`
selects the first matching socket on the Connections page so its details show
(`-openConnectionList closed|history` starts it on Closed recently or History;
`-openListenerChanges YES` selects Connections and opens listener review;
with debug `-listenerFixture YES` it shows made-up changes, never persisted,
with Accept and notifications disabled;
`-openHiddenSockets YES` selects Connections and opens Hidden Sockets, which
asks for the administrator's password at once;
`-openConnectionSearch <text>` opens History with a search),
`-openStartupSource <name>` picks the Source filter (the CLI source names or visible titles),
`-openStartupItem <text>` selects the first startup item whose label or name contains it,
`-openApp <name or bundle ID>` selects and scrolls to an app on the Apps page
(add `-openAppRemoval YES` to open its Move to Trash review),
`-openDriver <text>` selects the first extension on the Drivers page whose name
or bundle ID contains it (switching the vendor and status filters if they hide it),
`-openUser <name>` opens that user's top processes on the Users page (and
the system accounts, for root or a service account), `-openSystemSearch <text>`
searches the System page and `-openSystemCategory network` (or another group
in its jump bar) scrolls it to that group, and
`-openStorageScope <path>` scans that folder or volume when the Storage page
opens, with `-openStorageFolder <path inside it>` opening a folder in the
results, `-openStorageList largest|changes` showing the largest files or
what changed since the last saved scan of that folder, and
`-openStorageReconcile YES` unfolding "Where the space is", and
`-openStorageCleanup <path>[,<path>…]` opening the cleanup review with those
scan paths picked (use it with `-openStorageScope`; it never starts a move).
Pick a scope without protected folders (`/Library`, `/usr`, a test folder): Desktop,
Documents, Downloads and other apps' containers raise a privacy prompt.
`-openStorageSchedule <path>` selects Storage and opens its schedule sheet;
`-openStorageSchedules YES` opens the popover listing the schedules from the
line under the page.
In debug builds `-scheduleFixture YES` shows two made-up schedules (one due,
one with Permission needed), with refusal reasons and check times, never
persisted or run. Their actions, including the popover's Run Now, are disabled.

Storage's Scan This Automatically… offers Daily or Weekly and a local time
preference. Settings' Storage section lists schedules with Remove and Run Now.
`Settings.storageSchedules` holds a Codable JSON list (40 scopes at most), empty
by default, with path, cadence, preferred hour/minute, fixed due time, last attempt
and result. Sleep never advances a missed deadline. An unreadable or unmounted
scope records its reason and advances to the next cadence, while private folders
inside a readable one are counted in its result ("Scanned 4.2 GB · 3 folders
unreadable"), and growth notices compare only scans with the same count; transient eligibility
refusals keep Due since visible. Scheduling refuses Desktop, Documents, Downloads,
Library/Containers and Library/Group Containers, their descendants and their
parents (including Home and the startup disk), checking resolved paths too.
A scheduled scan must never trigger a privacy prompt, even with Full Disk Access.

Summaries carry optional `scheduled` provenance (version 1, cadence); absent is
manual, and reading old summaries never rewrites them. The scan picker marks
Scheduled · Daily/Weekly with a clock. Show Saved Scans reopens the bounded tree
without walking it, with unnamed remainders and no cleanup identities. Pick the
later scan, then Compare With an earlier one to compare any saved pair.
`otm du --schedule [--json]` reads only the app's persisted defaults domain and
lists due dates and last results; it never scans. Growth notifications default
off (`storageScheduleNotifications`); only turning on Settings' switch requests
notification permission. A readable scan growing by more than both 5 GB and 10%
against the previous saved scan may notify; otherwise nothing appears outside
Storage.
`-page <name>` works too. Each running copy keeps its own page
(`PageSelection`): it reads the saved page, or the one these arguments name,
once at launch, and saves each change for the next launch. It never follows
another copy, so a capture's copy and the user's own don't move each other.
Don't read the page through `@Setting(Settings.page)` (or raw `@AppStorage`):
a launch argument would pin it for the whole run and the sidebar would stop switching pages.
`-miniMonitorShown YES -miniMonitorLevel desktop -miniMonitorCorner bottomLeft`
shows the mini monitor for that run, but launch arguments pin those settings:
test its menu, its drag-to-corner and Settings with `defaults write` instead.
`-openWindowFrame "x y width height"` (screen points, origin bottom left) places
the window for that run and saves nothing, so a narrow capture never sets the
size the user's next window opens at. `-NSWindow Frame main` no longer places
it. Get the
window ID from `CGWindowListCopyWindowInfo`. Capture fails while the screen is
locked or the window is on another Space.

A Mac or VM with no sensors can still show a full Thermals page: in a debug
build, `-sensorFixture <file>` loads a recording from
`otm sensors --extremes 20 --json` in place of the sensors (`SensorFixture`).
Such a run records nothing to History, since the readings aren't that Mac's.

`-openResource cpu -openSpeedTest sustained` starts a sustained CPU run when the
CPU card first shows (2 min, or the length last picked). In a debug build,
`-sustainedFixture YES` shows three made-up sustained runs on this Mac, never
saved, with differing contexts (one on battery with the CPU busy, slowing as
the thermal state turns fair), so `-openResource benchmarks
-openBenchmarkCompare sustained:1,2` shows a comparison's context warnings.

Guided benchmark sessions (`BenchmarkGuidedSheet`, `BenchmarkWorkspace.runGuided`)
watch a 30 s quiet window, keeping current readings visible for at most 2 min.
`BenchmarkPreflightStatus` in OTMKit names the current blocking condition, counts the continuous
quiet streak against its requirement, and gives seconds left before the limit. CPU's row names
its current load. Battery and Low Power Mode explicitly say they are advisories that do not delay
readiness. Once quiet the sheet says Ready to proceed, with Proceed as the primary button.
Wait keeps watching; Proceed or Cancel ends the preflight sooner. The sheet uses only published CPU, memory pressure, thermal and
power readings from `BenchmarkContextFeed`; no extra sampler or work is added
to a closed sheet's ticks. Power comes from the published battery's plugged-in
state (AC for a Mac with no reported battery); UPS distinctions are not available
in this feed. A paused or stale sampler is unavailable, never quiet. Battery and
Low Power Mode are advisories; CPU above 10%, memory pressure, thermal pressure,
a sampling gap or changing power readings prevent settling. Proceed anyway and
Cancel are always available when the tests are idle.

A session discards one full warm-up pass, then measures N full passes (3 by
default, 1–10 offered) in
fixed CPU, GPU, optional disk, optional Internet order, through the existing
stores. A failed or cancelled pass stops the protocol; cancellation keeps the
store occupied until its runner has stopped. Each test uses its current workload
protocol, including GPU fill protocol v2. Each saved repeat has an optional
`session` block (schema 1, protocol
1, session ID, preflight samples and verdicts, repeat index and count). Older
results have no session; reading never rewrites them. History retention counts a
session as one entry and keeps its measured repeats together. Workspace picks,
comparisons and trends group repeats into one median with a spread enclosing
both the passes' figures and their internal timing ranges. Partial sessions say
so; unsupported protocols and ordinary runs cannot compare with sessions; the
measured repeat counts must also match.
Preflight differences are warnings, never claims about what caused a result.

`otm bench guided [cpu|gpu|all] [--repeats N] [--json]` uses the same protocol and history files.
The CLI has no app sampler, so its bounded preflight uses the existing CPU and
memory samplers. A quiet window starts the protocol; otherwise an interactive
terminal offers Wait, Proceed anyway or Cancel. Without a terminal, an unsettled
preflight exits without running tests. Ctrl-C cancels preflight or the active
runner. Progress and preflight notices go to stderr; JSON contains all measured
repeats, with their session blocks. `otm bench list` and `compare` group sessions.

In a debug build, `-openBenchmarkGuided cpu|gpu|all` selects Performance's
Benchmarks workspace and opens the preflight without starting a test. Add
`-guidedFixture YES` (or `-sustainedFixture YES`) for made-up CPU and GPU sessions
and preflight readings, never saved. The GPU fixture includes all three workloads: the
newest session has qualified fill timing, and the older sessions have verified counters.
It also supplies the GPU resource card; fixture runs are disabled. The waiting
fixture has low CPU and normal memory pressure
but fair thermal state, so it names heat as the blocker while battery remains an advisory.
Proceed and Run all are disabled for those
fixtures. Use `-openResource benchmarks -guidedFixture YES
-openBenchmarkCompare cpu:1,3` for grouped-session comparison screenshots.

Benchmark results keep a short Debug build badge on every debug result, including saved-run
pickers and tables. About debug builds folds the full qualification once per resource card or selected
workspace family, including a comparable pair's debug qualification (exports keep its full wording); CPU workloads
run slower without optimization, while GPU shaders use the GPU's own clock in either build.
Comparison refusals and figure-specific timing warnings remain explicit beside the figures.

## Conventions

- Persisted preferences are declared only in OTMKit's `Settings` registry
  (`SettingKey<Value, Stored>`): the key, typed default and meaning live there,
  and the stored type preserves each existing property-list encoding. Views
  use `@Setting(Settings.someKey)`; other code calls the key's `get`, `set` or
  `remove`. Add keys to `Settings.all` and pin their strings and encoded defaults
  in `SettingsTests`. Never construct a string key at a call site.
  `Setting` wraps `AppStorage`, so SwiftUI still observes changes. The page
  deliberately uses direct reads and writes in `PageSelection`, never `@Setting`:
  it reads once at launch and never follows another copy's page.
  Launch-only arguments (`openPage` and `LaunchArgument`) stay outside this
  registry: they are commands for a run, not preferences. Benchmark and speed-test
  result files belong to their history components; their disclosure, comparison
  and baseline preferences are settings and are registered.
- Process CPU is stored as Activity Monitor-style percent (100 = one core) and
  displayed through OTMKit's `CPUScale`, which defaults to share of the whole CPU.
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
- Grouped sorted by a figure (CPU, Memory and the rest) is one ranked list:
  `ProcessTreeBuilder.arrange` lifts the Apps, Background and System sections'
  rows into one level, each app's helpers still under it, since sections each
  sorted on their own put the busiest system processes under hundreds of idle
  ones. Name, PID and User keep the sections (`ProcessSortKey.ranksAcrossSections`);
  Flat is the one list without nesting. Name takes its preferred width
  (`processNameWidth`, 300 by default, set by dragging its edge, up to 900)
  where there's room, and less, down to its minimum, where there isn't; room
  left over goes after the last column, as in Activity Monitor, not into a
  gap between the names and their figures. Columns keep their widths under
  the autosave name "ProcessColumns" (renamed when the defaults change).
- Processes' toolbar End Task is a labelled split button: a click asks the
  selection to quit (as Delete does), its menu holds Force Quit…, which first
  confirms with the targets named (as Option-Delete does). Every Force Quit
  (toolbar, inspector, a row's menu) asks in `ForceQuitPrompt`'s words in
  OTMKit, with names read once as it opens, never per tick. Columns is always
  a submenu of the Grouped/Tree/Flat menu, which keeps the toolbar's search
  field whole at 1200 points.
- The Connections table hides columns to fit the same way (`ConnectionColumn`,
  Protocol first, then PID, then Seen for, then Scope; Process, Local, Remote and State
  always stay), and endpoints cut the address in the middle, never the port.
  Its seven summary cards fold into a strip of chips (rows from
  `GridMath.stripRows`) when they don't fit one row or the details are open,
  so the table keeps its height; a mouse-opened pane folds them a
  double-click later, so the second click still lands on the same row.
  History rows keep "PID 62194 · fd 4 · IPv4" under the process name, even
  as Protocol and First / last seen give way to fit; descriptors remain
  separate sockets, and the details header keeps the descriptor and family.
  The Startup table hides columns to fit too, through the shared `FittingColumn`,
  `TableColumnFitter` and `TableColumnSqueeze` (Components/ColumnFitting), in
  `StartupColumn`'s order (OTMKit's Layout/): Publisher first (a Third party
  badge in Name takes its place), then Source, Launches, Memory, CPU and last
  Kind, so Name and Status keep their room and a narrow table still says Agent
  or Daemon. Publisher is off while the filter leaves one publisher, and
  Source while the Source filter picks one, as every row would repeat it. The squeeze measures the room inside the
  scroll view's content insets (the sidebar floats over the page on macOS 26,
  and the scroll view runs on under it), and also refits when the table widens
  its own columns as SwiftUI hides one, leaving a column the user drags alone.
- Startup, Apps and Drivers size columns by what they hold
  (`ContentColumnWidth` in OTMKit's Layout/; `ColumnContent` measures values
  and titles in the table's fonts once per read of the rows, never per tick,
  through `ColumnWidths` or each page's `Widths`): a column of short values
  that repeat ("Universal", "Agent") stops where they end, so spare room goes
  after the last column, not into a gap; Startup's Source and Launches start
  at their widest value and give way whole rather than cut "Your LaunchAgents
  folder" short; Kind keeps room for "System agent", then Status for "Running
  PID 501" (`ColumnWidths.longForms`), each while that costs no column, so
  "Agent" and a bare "Running" appear only in a table too narrow. Beside each page's filters, `FilteredCount` says "Showing 2
  of 127 extensions" with Show All, which clears the filters and search, only
  while they hide rows; the status bar gives the total. Rows of filters wrap
  through `FlowRow`, with `centresRows` lining a short count up with the
  segmented controls beside it and `balancesRows: false` wrapping only what
  doesn't fit, so the count never takes a menu down with it.
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
  chain). A path shows its name over its folder, on at most two lines with
  the middle cut (`CopyableText(splitsPath: true)`, PathParts.compactFolder in
  OTMKit). Show full path expands selectable whole text; the tooltip and Copy
  always keep the whole path, with Copy Path beside Reveal in Finder: one
  control, never a scroll view of its own. This shared control serves Startup,
  Apps, Drivers and the process inspector. Identifiers too long for their
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
- The app, not AppKit, keeps the main window's frame (`mainWindowFrame`, "x y
  width height"). `MainWindowFrameKeeper` places the window before it shows,
  then saves it on each move and at the end of a live resize, never during one
  or in full screen, and puts the pre-full-screen frame back on leaving it
  (SwiftUI put back its opening frame). AppKit's autosave wrote "NSWindow Frame
  main" once, at opening, so a user's size never stuck while a narrow capture's
  did, and macOS 26's window restoration (saved state in a daemon container)
  reapplied the last killed window's frame after ours. So the window has no
  autosave name, isn't restorable, and `MainWindowFrame.ignoreSavedWindowState`
  registers `ApplePersistenceIgnoreState` and drops the old key before any
  window opens. `WindowPlacement` in OTMKit holds the rules: a first window is
  75% by 80% of the screen's usable area, within 1180×760 and 1440×940, never
  past the screen or under the 820×480 minimum, centred with a third of the
  spare height above; a saved frame goes back to the screen it mostly covers,
  or the middle of the main one if that's gone, shrunk and moved only enough
  to fit. Window > Return to Default Size applies the first-window size on the
  window's screen. `SidebarVisibilityStore` starts from the opening width.
- In a window under 900 points the sidebar hides itself and comes back when
  the window widens; a hide in a wide window is remembered (`sidebarHidden`)
  and a show in a narrow one lasts until the window crosses 900
  (`SidebarVisibility` in OTMKit, wired and saved by `SidebarVisibilityStore`).
  The View menu lists the pages (⌘1 to ⌘9).
  With it hidden, a page menu (`PageSwitcher`: the current page's title and the native menu
  chevron, out of the toolbar's glass so it sits with the title) sits before
  the separate navigation title. Keep this toolbar item: a title menu did nothing on macOS 26,
  and removing the separate title sent the sidebar toggle to overflow. In a narrow window Pause
  drops its word to make room, as do
  the pages' own items (`compactToolbar`: Startup's, Apps' and Drivers' read
  time loses "Read at" to its tooltip, Processes' End Task its word); keep
  the title visible, since hiding it (macOS 26) sent the sidebar toggle to the
  overflow menu for good once the sidebar was shown narrow. `PageFocus` gives the focus to the page's main table, or to
  nothing, never the toolbar's toggle (`HiddenSidebarFocus`). The detail column
  takes the window's height whatever its page asks for: a taller page moved the
  split view up and left a toolbar backdrop as a white band over the page.
  The toolbar's live badge speaks for the sampled metrics alone; Startup, Apps
  and Drivers say when their lists were read beside their Refresh
  (`InventoryRefresh`).
- The CPU graphs (Performance's, per core type, per core, by app, the Overview's
  CPU and Cores, and History's CPU chart) share one Auto / 100% setting, `CPUGraphScale` (`cpuGraphScale`).
  Auto bounds are `AutoScale` in OTMKit's Graphing/: round steps from 10%, grown
  at once, shrunk only after the data stays low; `AutoScaleBounds` keeps each
  live graph's between samples, and the top label says "auto scale". Keep
  segmented pickers on a live page out of `ViewThatFits`: it measured them
  again every tick (about half a percent of a core for the CPU graph's two),
  so that caption row is a small `Layout` instead.
- Each Performance device page opens the same way (`PerformanceHero.swift`):
  `DeviceHeader`, its title over a segmented `LevelBar` (Core Animation layers,
  the lit width eased in the render server; a nil fraction leaves it dim) and the
  current figure, then one `DeviceCard` whose main graph (`heroPlot`, which
  sets `fineGridRows`, so the graph draws `FineGridLines`: still rows, columns
  that scroll with the data as every live graph's do, `FineGridSpacing` in
  OTMKit) is `Hero.height` tall: the pane's measured height
  (`detailPaneHeight`, which changes with the window, never per tick) less
  `Hero.reserved`, clamped by `HeroHeight` in OTMKit, with the device's figures
  under it in `DeviceFigures` (columns from `FigureColumns`). Everything else
  follows that card. The CPU page's default is a graph per logical CPU
  (`CoreGraphGrid`: one AppKit view hosting a `StreamGraphView` a tile, busy time
  filled and kernel time, `CPUSample.coreSystem`, as a line; tiles laid out by
  `CoreAreaGrid` in OTMKit, 18 CPUs 6 by 3, core types on rows of their own
  where that costs nothing; `CoreGraphLayout` caps the whole tiles at 130 points
  by default, up to 180 when there is spare height, reserving another 100 points
  for the remaining summary rows and the toggle. "Larger graphs"
  (`cpuLargerGraphs` in Settings, off by default) fills the original area
  with the same graph views and no new per-frame work; the CPU and Overview's
  tiles are both drawn in
  `CoreTileLook`, so they read as one family). A GPU that doesn't report utilization graphs its
  memory in use there (`GPUHero`), its bar dim. The resource list's rows give a
  live graph in the device's colour and two lines of figures (`ResourceText`).
- History's chart legends draw a sample of each line as it's stroked
  (`HistoryLine.Stroke`, solid, dashed or dotted, over its fill when it has
  one), so two lines on a chart never differ by colour alone, and give what
  the line and its figure mean in the tooltip. During a replay the toolbar says
  "Collecting · 1 s" for this Mac and "Replay · 10×" for the file; the
  recording's name is the page banner's. History's transport says "Pause Replay"
  or "Resume Replay"; the toolbar and View menu say "Pause Live" or "Resume Live"
  while a file is shown, with the toolbar's short form kept narrow. Their help
  and accessibility labels name the separate controls (`UpdateControlLabels`).
- Graph colours come from the palette picked in Settings (`GraphColors`; the
  presets, Standard, Color-blind friendly and High contrast, are data in
  OTMKit's `GraphPalette`; `-graphPalette colorBlind|highContrast` picks one
  for a run). Read them through `Theme` in a view's body, so a change redraws
  the view; AppKit views that keep colours compare `GraphColors.shared.revision`
  (see `SensorReadingTable`). "By app" graphs colour apps with
  `Theme.appColors(for:in:)` (`SeriesSlots`), so an app keeps its colour as the
  ranking changes. Lines outweigh the grid and fills by the palette's
  `GraphEmphasis` (live graphs, History, the Settings preview): solid traces
  wider, light-mode traces deeper (`traceShade`; Color-blind friendly and High
  contrast keep their shades, already at their limits), grid and fills
  fainter; the unrecorded look keeps its weight. The retro display look
  (`RetroDisplay` in OTMKit, Settings' Retro display, `-retroDisplayStyle
  dotMatrix|segments`, `-retroDisplayTint`, `-retroDisplayGlow`,
  `-retroDisplayInstrument`), on by default as Dot matrix in Color. Color keeps the preset and the user's
  colours, made vivid (`GraphPalette.vivid`: each tone at the sRGB gamut edge
  in its own OKLCh hue, 0.05 deeper, via `PerceptualColor`), and each graph's
  panel takes its first line's colour: smoked glass (`RetroDisplay.smokedGlass`)
  with a trace of it, a near-white grid, edge and labels lit
  (`RetroDisplay.Ruling`), a tighter, brighter bloom (`RetroDisplay.bloom`), a
  faint fill (`GraphEmphasis.vivid`), plain cards under it and key names in
  their lines' colours. Color's Instrument panels toggle (off by default;
  `RetroDisplay.instrument`, in force as `isInstrument`) floods each panel
  with its colour instead (`instrumentGlass`, `instrumentFlood`), ruled in
  that colour, with a brighter bloom, deep fills (`GraphEmphasis.instrument`),
  cards flooded too (`CardSurfaceView.Wash.flooded`), Overview's graphs on a
  16-row fine grid and headed by `InstrumentStrip`, a dot-matrix strip
  spelling the title (`ReadoutGlyphs.titleDots`) with the figure at its end;
  the one-colour tints
  put their palette (`GraphPalette.retro`) in place of the preset and the
  user's colours while on. Live graphs draw as dark panels in either
  appearance (the view's layer background and border, forced dark, grid and
  labels in the panel's light, `RetroDisplay.panel(lit:)`), and `AnimatedNumber` draws figures as
  `ReadoutGlyphs`' dots or bars (`RetroFigures`) into the same cached glyph
  bitmaps, glow baked in and only in dark mode, so ticks cost what they did.
  A one-colour palette is the tint's hue only, lines that share a chart told apart by
  brightness (`RetroDisplay.levels`, even OKLab steps). Under a one-colour tint the window follows
  (Color leaves it be; card figures take their card's colour):
  `.tint(GraphColors.retroAccent)` on controls, card titles in the accent, a
  faint wash behind pages (`retroWash`), and link buttons take
  `.linkButtonStyle()`, not `.buttonStyle(.link)`, whose colour ignores tint.
  On History a run of readings
  under about 8 points wide (`HistoryPoint.unfilled`) gets no fill, only its
  line and end dots, so it never reads as a bar.
- Secondary text (labels, captions, units, footnotes) takes
  `.foregroundStyle(.secondaryText)` and `.font(.metadata)` (12 pt, the
  floor for anything a reading depends on); explanations meant to be read
  (what a reading means, why it's missing, what a button does)
  `.font(.explanation)` (12 pt); and table and list rows, graph legends and
  the process inspector's facts `.font(.tableText)` (13 pt), all from
  `Graphs.swift`. Live graphs' axis labels and coverage caption are 12 pt
  too (`StreamGraphView.captionFont`), placed so the caption still fits under
  the middle label of a 72-point graph. The Thermals table's
  rows are 13 pt (body), with its supporting text at 12 pt. Benchmarks'
  comparison table keeps that size in a narrow window by dropping a figure's
  variant under its name, stacking the two spreads and, where "Higher ·
  conditions differ" won't fit even on two lines, keeping only the direction
  (`shortVerdictTitle`), since the heading over it names the conditions
  (`ViewThatFits`). The system's `.secondary` falls under 4.5:1 on the tinted cards (see `TextTone`).
  Search finds are marked in primary ink, bold, over `TextTone.highlight`,
  which keeps 4.5:1 on every card in both appearances.
  A SwiftUI `Table` that may hold only a few rows takes `.fitsTableToRows(_:)`
  (`TableFit.swift`), so no empty striped rows follow the last one (Apps and
  Drivers, in a `VStack` over a `Spacer`, so a short table stops at its last row).
  It trims only while every row fits and no legacy horizontal scroller shows
  under them, judging an already-trimmed table by the room it was offered.
- Commits end with the Co-Authored-By trailer. Only push to github.com/jtn0123.
