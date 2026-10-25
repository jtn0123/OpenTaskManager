//! The History page: what the recorder kept over the last hour to week,
//! read from its files when the page opens or the range changes, then
//! topped up with new records while it's shown. Graph paths are rebuilt
//! only then and when the window resizes; picking a moment only changes
//! its figures and the list under the graphs.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use otm_core::clock;
use otm_core::format::{MISSING, axis_rate, bytes, duration, percent, rate};
use otm_core::recorder::{self, KEEP_DAYS, Record, SPAN_MS};
use otm_core::scale::round_bytes;
use slint::{Color, Model};

use crate::{AppWindow, CloneStrong, HistoryGraph, View, graph};

/// The ranges offered, in milliseconds: an hour, 6 hours, a day, a week.
pub(crate) const RANGES: [u64; 4] = [3_600_000, 6 * 3_600_000, 86_400_000, 7 * 86_400_000];

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64)
}

/// What one graph shows: its title, colour and the figure each record gives.
struct Graph {
    title: &'static str,
    accent: Color,
    /// The line, and a dashed second line where there is one.
    first: fn(&Record) -> Option<f64>,
    second: Option<fn(&Record) -> Option<f64>>,
    /// Percent graphs fill under the line and top out at 100%.
    percent: bool,
    /// The figure at a record, in words.
    describe: fn(&Record) -> String,
}

fn graphs(with_gpu: bool) -> Vec<Graph> {
    let mut graphs = vec![
        Graph {
            title: "CPU",
            accent: Color::from_rgb_u8(0x35, 0xd0, 0x7f),
            first: |record| Some(f64::from(record.cpu)),
            second: None,
            percent: true,
            describe: |record| {
                format!("{} · peak {}", percent(Some(f64::from(record.cpu))), percent(Some(f64::from(record.cpu_peak))))
            },
        },
        Graph {
            title: "Memory",
            accent: Color::from_rgb_u8(0xb3, 0x8c, 0xff),
            first: |record| {
                (record.memory_total > 0).then(|| record.memory_used as f64 / record.memory_total as f64 * 100.0)
            },
            second: None,
            percent: true,
            describe: |record| bytes(Some(record.memory_used as f64)),
        },
        Graph {
            title: "Disk",
            accent: Color::from_rgb_u8(0xff, 0xb5, 0x47),
            first: |record| record.disk_read,
            second: Some(|record| record.disk_write),
            percent: false,
            describe: |record| format!("R {} · W {}", rate(record.disk_read), rate(record.disk_write)),
        },
        Graph {
            title: "Network",
            accent: Color::from_rgb_u8(0x4f, 0xb8, 0xff),
            first: |record| record.net_in,
            second: Some(|record| record.net_out),
            percent: false,
            describe: |record| format!("In {} · out {}", rate(record.net_in), rate(record.net_out)),
        },
    ];
    if with_gpu {
        graphs.push(Graph {
            title: "GPU",
            accent: Color::from_rgb_u8(0xff, 0x7a, 0xa8),
            first: |record| record.gpu.map(f64::from),
            second: None,
            percent: true,
            describe: |record| percent(record.gpu.map(f64::from)),
        });
    }
    graphs
}

impl View {
    /// The range's records, read from the files.
    pub(crate) fn load_history(&mut self) {
        let to = now_ms();
        let from = to.saturating_sub(RANGES[self.history_range]);
        self.history = self.history_store.as_ref().map(|store| store.read(from, to)).unwrap_or_default();
        self.history_size = self.history_store.as_ref().map_or(0, |store| store.size());
        self.history_loaded = Some(Instant::now());
        self.draw_history();
    }

    /// Adds what was recorded since the last read, at most every 10 s, while the page shows.
    pub(crate) fn top_up_history(&mut self) {
        if self.page != 2 || self.history_loaded.is_some_and(|at| at.elapsed() < Duration::from_millis(SPAN_MS)) {
            return;
        }
        let Some(store) = &self.history_store else { return };
        let to = now_ms();
        let from = to.saturating_sub(RANGES[self.history_range]);
        let after = self.history.last().map_or(from, |record| record.time_ms + 1);
        self.history.retain(|record| record.time_ms >= from);
        self.history.extend(store.read(after, to));
        self.history_size = store.size();
        self.history_loaded = Some(Instant::now());
        self.draw_history();
    }

    pub(crate) fn choose_history_range(&mut self, index: i32) {
        if let Some(index) = usize::try_from(index).ok().filter(|index| *index < RANGES.len()) {
            self.history_range = index;
            self.load_history();
        }
    }

    pub(crate) fn move_history_moment(&mut self, moment: f32) {
        self.history_moment = moment.clamp(0.0, 1000.0);
        if let Some(window) = self.window.clone_strong() {
            window.set_history_moment(self.history_moment);
            self.draw_moment(&window, now_ms());
        }
    }

    pub(crate) fn set_recording(&mut self, on: bool) {
        self.recording.store(on, std::sync::atomic::Ordering::Relaxed);
        self.save_settings();
        self.draw_history();
    }

    /// The graphs' paths and the summary, then the chosen moment.
    pub(crate) fn draw_history(&mut self) {
        let Some(window) = self.window.clone_strong() else { return };
        if self.page != 2 {
            return;
        }
        let to = now_ms();
        let range = RANGES[self.history_range];
        let from = to.saturating_sub(range);
        let width = f64::from(window.get_history_plot_width()).max(10.0);
        let frame = graph::Frame {
            width,
            height: f64::from(window.get_history_plot_height()),
            span: ((width / 2.0) as usize).clamp(30, 720),
        };
        let grid = graph::grid(frame, 0);
        let with_gpu = self.has_gpu || self.history.iter().any(|record| record.gpu.is_some());
        let shown: Vec<HistoryGraph> = graphs(with_gpu)
            .iter()
            .map(|graph| {
                let first = recorder::series(&self.history, from, to, frame.span, graph.first);
                let second = graph.second.map(|pick| recorder::series(&self.history, from, to, frame.span, pick));
                let top = if graph.percent {
                    100.0
                } else {
                    let most = first.iter().chain(second.iter().flatten()).flatten().fold(0.0f64, |a, b| a.max(*b));
                    round_bytes(most.max(16.0 * 1024.0))
                };
                HistoryGraph {
                    title: graph.title.into(),
                    accent: graph.accent,
                    value: MISSING.into(),
                    top_label: if graph.percent { "100%".to_owned() } else { axis_rate(top) }.into(),
                    grid: grid.as_str().into(),
                    area: if graph.percent { graph::area(&first, top, frame) } else { graph::NOTHING.to_owned() }
                        .into(),
                    line: graph::line(&first, top, frame).into(),
                    dashed: second
                        .map_or_else(|| graph::NOTHING.to_owned(), |second| graph::dashed(&second, top, frame, 0))
                        .into(),
                }
            })
            .collect();
        if self.history_graphs.row_count() == shown.len() {
            for (index, graph) in shown.into_iter().enumerate() {
                self.history_graphs.set_row_data(index, graph);
            }
        } else {
            self.history_graphs.set_vec(shown);
        }
        let recorded: u64 = self.history.iter().map(|record| record.span_ms).sum();
        let recording = self.recording.load(std::sync::atomic::Ordering::Relaxed);
        let summary = match (self.history.is_empty(), recording) {
            (true, false) => "Recording is off: nothing is kept.".to_owned(),
            (true, true) => "Nothing recorded in this range yet: a record comes every 10 s.".to_owned(),
            (false, _) => format!(
                "{} recorded in this range{} · {} on disk, kept {KEEP_DAYS} days",
                duration(recorded / 1000),
                if recording { "" } else { " (recording is off)" },
                bytes(Some(self.history_size as f64))
            ),
        };
        window.set_history_summary(summary.into());
        window.set_history_range(self.history_range as i32);
        window.set_history_start(clock::moment(from, to).into());
        window.set_history_moment(self.history_moment);
        self.draw_moment(&window, to);
    }

    /// The figures at the chosen moment, and what was busiest then.
    fn draw_moment(&self, window: &AppWindow, now: u64) {
        let range = RANGES[self.history_range];
        let from = now.saturating_sub(range);
        let moment = from + (range as f64 * f64::from(self.history_moment) / 1000.0) as u64;
        // At "now", the latest record stands for it while recording carries on.
        let record = if self.history_moment >= 999.5 {
            self.history.last().filter(|record| now.saturating_sub(record.time_ms) <= 2 * SPAN_MS)
        } else {
            recorder::at(&self.history, moment)
        };
        let with_gpu = self.history_graphs.row_count() > 4;
        for (index, graph) in graphs(with_gpu).iter().enumerate() {
            if let Some(mut shown) = self.history_graphs.row_data(index) {
                let value: slint::SharedString = record.map_or_else(|| MISSING.to_owned(), graph.describe).into();
                if shown.value != value {
                    shown.value = value;
                    self.history_graphs.set_row_data(index, shown);
                }
            }
        }
        let (title, lines) = match record {
            Some(record) => {
                let when = clock::moment(record.time_ms, now);
                let title = format!(
                    "{when} · CPU {} · memory {}",
                    percent(Some(f64::from(record.cpu))),
                    bytes(Some(record.memory_used as f64))
                );
                let lines: Vec<String> = if record.top.is_empty() {
                    vec!["Processes weren't read in this span.".to_owned()]
                } else {
                    record
                        .top
                        .iter()
                        .take(8)
                        .map(|process| {
                            format!(
                                "{} (PID {}) · CPU {} · memory {}",
                                process.name,
                                process.key.pid,
                                percent(process.cpu.map(f64::from)),
                                bytes(process.memory.map(|memory| memory as f64))
                            )
                        })
                        .collect()
                };
                (title, lines)
            }
            None => (
                format!("Nothing recorded at {}", clock::moment(moment, now)),
                vec!["OpenTaskManager wasn't running or recording, or the computer was asleep.".to_owned()],
            ),
        };
        window.set_history_moment_title(title.into());
        let lines: Vec<slint::SharedString> = lines.into_iter().map(Into::into).collect();
        window.set_history_moment_lines(slint::ModelRc::new(slint::VecModel::from(lines)));
    }
}
