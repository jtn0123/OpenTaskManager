// Where samples come from: the Rust core inside the app, or, opened in a
// plain browser for layout work, a preview that makes up plausible figures
// and says so on screen.

import type { HistoryReply } from "./bindings/HistoryReply";
import type { ProcessRow } from "./bindings/ProcessRow";
import type { Snapshot } from "./bindings/Snapshot";
import type { Tick } from "./bindings/Tick";

export interface Source {
  readonly isPreview: boolean;
  history(): Promise<HistoryReply>;
  /** Calls `handler` with each sample; returns a function that stops it. */
  onTick(handler: (tick: Tick) => void): Promise<() => void>;
}

export async function connect(): Promise<Source> {
  if ("__TAURI_INTERNALS__" in window) {
    const [{ invoke }, { listen }] = await Promise.all([import("@tauri-apps/api/core"), import("@tauri-apps/api/event")]);
    return {
      isPreview: false,
      history: () => invoke<HistoryReply>("history"),
      onTick: (handler) => listen<Tick>("tick", (event) => handler(event.payload)),
    };
  }
  return new Preview();
}

/** Made-up figures for a browser preview; never shown inside the app. */
class Preview implements Source {
  readonly isPreview = true;
  private readonly cores = 8;
  private readonly snapshots: Snapshot[] = [];
  private processes: ProcessRow[] = [];
  private time = Date.now() - 60_000;
  private phase = 0;

  constructor() {
    const names = ["code", "firefox", "Isolated Web Content", "gnome-shell", "Xwayland", "pipewire", "systemd", "dbus-daemon",
      "NetworkManager", "opentaskmanager", "WebKitWebProcess", "bash", "node", "rust-analyzer", "cargo", "sshd", "cron", "snapd"];
    for (let pid = 1; pid <= 180; pid += 1) {
      const name = names[pid % names.length] ?? "process";
      const isRoot = pid % 4 === 0;
      this.processes.push({
        key: { pid: pid * 37, startTime: 1_761_000_000 + pid },
        name,
        user: isRoot ? "root" : "justin",
        cpu: pid === 7 ? null : 0,
        memory: (pid % 23) * 18_000_000 + 4_000_000,
        diskRead: isRoot || pid === 7 ? null : 0,
        diskWrite: isRoot || pid === 7 ? null : 0,
      });
    }
    for (let i = 0; i < 60; i += 1) this.snapshots.push(this.advance());
  }

  private wave(offset: number, amount: number): number {
    return Math.max(0, (Math.sin(this.phase / 7 + offset) + 1) / 2) * amount + Math.random() * amount * 0.15;
  }

  private advance(): Snapshot {
    this.phase += 1;
    this.time += 1000;
    const cores = Array.from({ length: this.cores }, (_, core) => Math.min(100, this.wave(core, 70)));
    const busy = cores.reduce((sum, value) => sum + value, 0) / this.cores;
    const gap = this.phase % 37 > 33;
    return {
      timeMs: this.time,
      interval: 1,
      cpu: busy,
      cores,
      memoryUsed: 9.4e9 + this.wave(1, 1.2e9),
      memoryTotal: 16 * 1024 ** 3,
      swapUsed: 0.4e9,
      swapTotal: 2 * 1024 ** 3,
      disk: gap ? null : { read: this.wave(2, 4e6), write: this.wave(3, 1.5e6) },
      network: { received: this.wave(4, 900e3), sent: this.wave(5, 200e3) },
    };
  }

  private scales(): { disk: number; network: number } {
    return { disk: 5 * 1024 ** 2, network: 1024 ** 2 };
  }

  history(): Promise<HistoryReply> {
    return Promise.resolve({ snapshots: [...this.snapshots], scales: this.scales(), logicalCpus: this.cores, capacity: 60, interval: 1, slideGraphs: null });
  }

  onTick(handler: (tick: Tick) => void): Promise<() => void> {
    const timer = window.setInterval(() => {
      const snapshot = this.advance();
      this.processes = this.processes.map((row, index) =>
        row.cpu === null
          ? row
          : {
              ...row,
              cpu: Math.max(0, index < 6 ? this.wave(index, 120) : Math.random() * 3 - 1.2),
              diskRead: row.diskRead === null ? null : Math.random() < 0.1 ? Math.random() * 2e6 : 0,
              diskWrite: row.diskWrite === null ? null : Math.random() < 0.05 ? Math.random() * 1e6 : 0,
            },
      );
      handler({ snapshot, processes: this.processes, scales: this.scales() });
    }, 1000);
    return Promise.resolve(() => window.clearInterval(timer));
  }
}
