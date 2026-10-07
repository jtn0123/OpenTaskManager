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
  Graphing/ for axis and curve maths; System/LaunchItems, LaunchTriggers and
  Launchctl read launchd plists and parse `launchctl` output),
  the `otm` CLI, and Swift Testing tests. Keep pure logic here so it can be
  tested.
- `App/Sources`: `AppModel` (observable state and history), Views/Overview,
  Views/Processes (NSOutlineView table in `ProcessOutlineView`), Views/Performance,
  Views/History (the flight recorder's graphs; `FlightRecorder` in OTMKit writes
  a `HistoryRecord` every 10 s to ~/Library/Application Support/OpenTaskManager),
  Views/Connections (socket table; `ConnectionStore` runs the walk),
  Views/Startup (launchd items in a SwiftUI `Table`, scanned off the main actor
  when the page opens and on Refresh, never per tick),
  Views/Users (per-user totals; the grouping is `UserUsageBuilder` in OTMKit),
  Views/System (hardware and security facts, read once when the page opens, never
  per tick; the rows come from `SystemReport` in OTMKit),
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
- Graphs go through `GraphView` (`StreamGraph.swift`): paths are rebuilt once
  per sample and a Core Animation scroll slides them between samples. Changing
  numbers go through `AnimatedNumber`, which composes cached glyph bitmaps.
  Don't swap either for SwiftUI `Path` or `Text` animations. The History page
  is the exception: its graphs are static Swift Charts, reloaded once per graph
  point, and its scrubber line is an overlay that alone reads the pointer, so
  hovering never redraws the charts.
- Rows of cards go through `FillGrid`, not an adaptive `LazyVGrid`: it fills
  every row edge to edge and evens out card heights, so a card that isn't
  available on this Mac (no GPU, no power sensors) never leaves a hole.
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

`-openPage Overview|Processes|Performance|History|Connections|Startup|Users|System` sets the starting page, and
`-openResource cpu|memory|gpu|disk|network|power|sensors` the Performance detail
(`-openScroll bottom` starts the page scrolled to the end), `-openProcess <pid>`
selects a process so its inspector shows, `-openConnection <port or text>`
selects the first matching socket on the Connections page so its details show,
`-openStartupItem <text>` selects the first startup item whose label or name contains it,
and `-openUser <name>` opens that user's top processes on the Users page (and
the system accounts, for root or a service account). Don't pass
`-page` itself: a launch argument pins that setting for the whole run, so the
sidebar stops working in that instance. The exception is a capture while other
instances run: `-openPage` saves the page, so every running instance follows
the last launch, and `-page <name>` keeps a throwaway instance on its page. Get the
window ID from `CGWindowListCopyWindowInfo`. Capture fails while the screen is
locked or the window is on another Space.

## Conventions

- Process CPU is stored as Activity Monitor-style percent (100 = one core) and
  displayed through `CPUScale`, which defaults to share of the whole CPU.
- Restricted processes (root and other users) only have CPU and memory, read
  via `/bin/ps`. Show "—" for other fields, never zero.
- Commits end with the Co-Authored-By trailer. Only push to github.com/jtn0123.
