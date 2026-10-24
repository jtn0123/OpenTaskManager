import "./styles.css";

import type { ProcessRow } from "./bindings/ProcessRow";
import type { Scales } from "./bindings/Scales";
import type { Snapshot } from "./bindings/Snapshot";
import { axisRate, bytes, MISSING, percent, rate } from "./format";
import { type Line, LiveGraph, slidesSmoothly } from "./graph";
import { connect } from "./source";
import { type Column, ProcessTable } from "./table";

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (found === null) throw new Error(`The page is missing #${id}.`);
  return found as T;
}

/** A graph card: title and current figure over the graph, a caption under it. */
class Card {
  readonly graph: LiveGraph;
  private readonly value: HTMLSpanElement;
  private readonly caption: HTMLParagraphElement;

  constructor(
    host: HTMLElement,
    title: string,
    accent: string,
    graph: { span: number; intervalMs: number; slides: boolean },
    describeTop: (top: number) => string,
  ) {
    const card = document.createElement("article");
    card.className = "card";
    card.style.setProperty("--accent", accent);
    const head = document.createElement("div");
    head.className = "card-head";
    const name = document.createElement("h2");
    name.textContent = title;
    this.value = document.createElement("span");
    this.value.className = "card-value";
    head.append(name, this.value);
    const graphHost = document.createElement("div");
    graphHost.className = "graph";
    this.caption = document.createElement("p");
    this.caption.className = "card-caption";
    card.append(head, graphHost, this.caption);
    host.append(card);
    this.graph = new LiveGraph(graphHost, graph.span, graph.intervalMs, graph.slides, describeTop);
  }

  set(value: string, caption: string): void {
    if (this.value.textContent !== value) this.value.textContent = value;
    if (this.caption.textContent !== caption) this.caption.textContent = caption;
  }
}

const colours = {
  cpu: "#35d07f",
  memory: "#b38cff",
  disk: "#ffb547",
  network: "#4fb8ff",
};

async function start(): Promise<void> {
  const source = await connect();
  const history = await source.history();
  const span = history.capacity;
  const intervalMs = history.interval * 1000;
  let logicalCpus = history.logicalCpus;
  let snapshots: Snapshot[] = history.snapshots.slice(-(span + 1));
  let scales: Scales = history.scales;
  let samples = snapshots.length;
  let processCount: number | null = null;

  if (source.isPreview) document.body.classList.add("preview");

  // Chosen at launch, or slide only where a GPU is confirmed.
  const slides = history.slideGraphs ?? slidesSmoothly;
  const motion = { span, intervalMs, slides };
  const graphs = element<HTMLElement>("graphs");
  const cpu = new Card(graphs, "CPU", colours.cpu, motion, () => "100%");
  const memory = new Card(graphs, "Memory", colours.memory, motion, () => "100%");
  const disk = new Card(graphs, "Disk", colours.disk, motion, axisRate);
  const network = new Card(graphs, "Network", colours.network, motion, axisRate);

  const series = (pick: (snapshot: Snapshot) => number | null): (number | null)[] => snapshots.map(pick);

  function drawGraphs(): void {
    const latest = snapshots[snapshots.length - 1];
    cpu.graph.show([{ values: series((s) => s.cpu), color: colours.cpu, fill: true, label: "CPU, percent busy" }], 100, samples);
    memory.graph.show(
      [{ values: series((s) => (s.memoryTotal > 0 ? (s.memoryUsed / s.memoryTotal) * 100 : null)), color: colours.memory, fill: true, label: "Memory in use, percent" }],
      100,
      samples,
    );
    const diskLines: Line[] = [
      { values: series((s) => s.disk?.read ?? null), color: colours.disk, label: "Disk read, solid" },
      { values: series((s) => s.disk?.write ?? null), color: colours.disk, dashed: true, label: "Disk write, dashed" },
    ];
    disk.graph.show(diskLines, scales.disk, samples);
    const networkLines: Line[] = [
      { values: series((s) => s.network?.received ?? null), color: colours.network, label: "Network received, solid" },
      { values: series((s) => s.network?.sent ?? null), color: colours.network, dashed: true, label: "Network sent, dashed" },
    ];
    network.graph.show(networkLines, scales.network, samples);

    if (latest === undefined) {
      for (const card of [cpu, memory, disk, network]) card.set(MISSING, "Waiting for the first sample");
      return;
    }
    cpu.set(percent(latest.cpu), `${latest.cores.length || logicalCpus} logical CPUs`);
    const share = latest.memoryTotal > 0 ? (latest.memoryUsed / latest.memoryTotal) * 100 : null;
    memory.set(percent(share), `${bytes(latest.memoryUsed)} of ${bytes(latest.memoryTotal)} · swap ${bytes(latest.swapUsed)}`);
    disk.set(
      latest.disk === null ? MISSING : rate(latest.disk.read + latest.disk.write),
      latest.disk === null ? "No disk reported its traffic" : `Read ${rate(latest.disk.read)} · write ${rate(latest.disk.write)} (dashed)`,
    );
    network.set(
      latest.network === null ? MISSING : rate(latest.network.received + latest.network.sent),
      latest.network === null
        ? "No network interface listed"
        : `In ${rate(latest.network.received)} · out ${rate(latest.network.sent)} (dashed)`,
    );
  }

  // CPU is a share of the whole machine; the core reports Activity Monitor's per-CPU percent.
  const machineShare = (row: ProcessRow): number | null => (row.cpu === null ? null : row.cpu / Math.max(1, logicalCpus));
  const columns: Column[] = [
    { id: "name", title: "Name", numeric: false, sortValue: (row) => row.name, text: (row) => row.name },
    { id: "pid", title: "PID", numeric: true, sortValue: (row) => row.key.pid, text: (row) => String(row.key.pid) },
    { id: "user", title: "User", numeric: false, sortValue: (row) => row.user, text: (row) => row.user ?? MISSING },
    { id: "cpu", title: "CPU", numeric: true, sortValue: machineShare, text: (row) => percent(machineShare(row)) },
    { id: "memory", title: "Memory", numeric: true, sortValue: (row) => row.memory, text: (row) => bytes(row.memory) },
    { id: "read", title: "Disk read", numeric: true, sortValue: (row) => row.diskRead, text: (row) => rate(row.diskRead) },
    { id: "write", title: "Disk write", numeric: true, sortValue: (row) => row.diskWrite, text: (row) => rate(row.diskWrite) },
  ];
  const table = new ProcessTable(element<HTMLElement>("processes"), columns, "cpu");
  const status = element<HTMLElement>("status");
  let shownCount = 0;
  function describe(): void {
    const preview = source.isPreview ? "Preview with made-up figures · " : "";
    const count =
      processCount === null
        ? "Reading processes…"
        : shownCount === processCount
          ? `${processCount} processes`
          : `Showing ${shownCount} of ${processCount} processes`;
    const reason = history.slideGraphs === null ? "no GPU confirmed" : "chosen at launch";
    const stepping = slides ? "" : ` · graphs step each sample: ${reason}`;
    status.textContent = `${preview}${count} · every ${history.interval} s${stepping} · CPU as a share of all ${logicalCpus} CPUs · “—” means the system didn't say`;
  }
  table.onCount = (shown, total) => {
    shownCount = shown;
    processCount = total;
    describe();
  };
  element<HTMLInputElement>("search").addEventListener("input", (event) => {
    table.search((event.target as HTMLInputElement).value);
  });
  describe();
  drawGraphs();

  await source.onTick((tick) => {
    snapshots = [...snapshots.slice(-span), tick.snapshot];
    scales = tick.scales;
    samples += 1;
    logicalCpus = tick.snapshot.cores.length || logicalCpus;
    drawGraphs();
    if (tick.processes !== null) table.update(tick.processes);
  });

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    for (const card of [cpu, memory, disk, network]) card.graph.redraw();
  });
}

start().catch((error: unknown) => {
  document.body.textContent = `OpenTaskManager couldn't start: ${String(error)}`;
});
