// A live graph drawn once per sample and slid by the compositor between
// samples, as the Mac app's Core Animation graphs are: nothing is drawn per
// frame, so a smooth graph costs no more than a still one.

export interface Line {
  /** Oldest first; null leaves a gap, never a zero. */
  readonly values: readonly (number | null)[];
  readonly color: string;
  readonly dashed?: boolean;
  readonly fill?: boolean;
  readonly label: string;
}

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

/**
 * Sliding is free where a GPU composites the page and expensive where the
 * CPU does (a VM, a remote session, a missing driver): measured in WSL's
 * software renderer, four sliding graphs cost more than a whole core. There
 * the graphs step once per sample instead.
 */
const renderer: string | null = (() => {
  const gl = document.createElement("canvas").getContext("webgl");
  if (gl === null) return null;
  const info = gl.getExtension("WEBGL_debug_renderer_info");
  const name = String(gl.getParameter(info === null ? gl.RENDERER : info.UNMASKED_RENDERER_WEBGL));
  gl.getExtension("WEBGL_lose_context")?.loseContext();
  return name;
})();

const SOFTWARE = /llvmpipe|softpipe|lavapipe|swiftshader|software|basic render/i;
const HARDWARE = /nvidia|geforce|quadro|amd|radeon|intel|iris|uhd|apple|adreno|mali|powervr|direct3d|d3d1|metal|vulkan/i;

/**
 * Only a renderer named as a GPU slides; an unknown or hidden one steps,
 * which is cheap everywhere. Only Chromium's web view (WebView2 on Windows)
 * names the real GPU: WebKit (Linux) calls every renderer "Apple GPU" to
 * resist fingerprinting, so there graphs step unless `--slide-graphs` asks.
 */
export const slidesSmoothly: boolean =
  /\bChrome\//.test(navigator.userAgent) && renderer !== null && HARDWARE.test(renderer) && !SOFTWARE.test(renderer);
const ROWS = 4;
/** A vertical rule every this many samples, moving with the data. */
const COLUMN_EVERY = 10;

export class LiveGraph {
  private readonly viewport: HTMLDivElement;
  private readonly canvas: HTMLCanvasElement;
  private readonly context: CanvasRenderingContext2D;
  private readonly topLabel: HTMLSpanElement;
  private readonly span: number;
  private readonly intervalMs: number;
  private readonly describeTop: (top: number) => string;
  private readonly slides: boolean;
  private animation: Animation | null = null;
  private lines: readonly Line[] = [];
  private top = 1;
  private samples = 0;
  private width = 0;
  private height = 0;

  constructor(host: HTMLElement, span: number, intervalMs: number, slides: boolean, describeTop: (top: number) => string) {
    this.span = Math.max(2, span);
    this.slides = slides;
    this.intervalMs = intervalMs;
    this.describeTop = describeTop;
    this.viewport = document.createElement("div");
    this.viewport.className = "graph-viewport";
    this.canvas = document.createElement("canvas");
    this.canvas.className = "graph-strip";
    this.canvas.setAttribute("aria-hidden", "true");
    const context = this.canvas.getContext("2d", { alpha: false });
    if (context === null) throw new Error("This system's web view can't draw 2D graphs.");
    this.context = context;
    this.topLabel = document.createElement("span");
    this.topLabel.className = "graph-top";
    this.viewport.append(this.canvas, this.topLabel);
    host.append(this.viewport);
    new ResizeObserver(() => this.layout()).observe(this.viewport);
  }

  /** Draws the newest values and slides them in over the next interval. */
  show(lines: readonly Line[], top: number, samples: number): void {
    this.lines = lines;
    this.top = top > 0 && Number.isFinite(top) ? top : 1;
    this.samples = samples;
    this.topLabel.textContent = this.describeTop(this.top);
    this.viewport.setAttribute("aria-label", lines.map((line) => line.label).join(", "));
    if (document.hidden || this.width === 0) return;
    this.draw();
    this.slide();
  }

  /** Draws in place without sliding: after a resize or the window reappearing. */
  redraw(): void {
    if (this.width === 0) return;
    this.draw();
    this.animation?.cancel();
    this.animation = null;
    this.canvas.style.transform = `translateX(${-this.step()}px)`;
  }

  private step(): number {
    return this.width / (this.span - 1);
  }

  private layout(): void {
    const box = this.viewport.getBoundingClientRect();
    this.width = box.width;
    this.height = box.height;
    const ratio = window.devicePixelRatio || 1;
    const stripWidth = this.width + this.step();
    this.canvas.style.width = `${stripWidth}px`;
    this.canvas.style.height = `${this.height}px`;
    this.canvas.width = Math.max(1, Math.round(stripWidth * ratio));
    this.canvas.height = Math.max(1, Math.round(this.height * ratio));
    this.context.setTransform(ratio, 0, 0, ratio, 0, 0);
    this.redraw();
  }

  /** The strip is one step wider than the view: the newest point starts just past its right edge. */
  private draw(): void {
    const context = this.context;
    const step = this.step();
    const stripWidth = this.width + step;
    const style = getComputedStyle(this.viewport);
    context.fillStyle = style.getPropertyValue("--panel").trim() || "#0b0f14";
    context.fillRect(0, 0, stripWidth, this.height);

    context.strokeStyle = style.getPropertyValue("--grid").trim() || "rgba(255, 255, 255, 0.08)";
    context.lineWidth = 1;
    context.setLineDash([]);
    context.beginPath();
    for (let row = 1; row < ROWS; row += 1) {
      const y = Math.round((this.height * row) / ROWS) + 0.5;
      context.moveTo(0, y);
      context.lineTo(stripWidth, y);
    }
    for (let age = 0; age <= this.span; age += 1) {
      if ((this.samples - age) % COLUMN_EVERY !== 0) continue;
      const x = Math.round(stripWidth - age * step) + 0.5;
      context.moveTo(x, 0);
      context.lineTo(x, this.height);
    }
    context.stroke();

    for (const line of this.lines) this.plot(line, step, stripWidth);
  }

  private plot(line: Line, step: number, stripWidth: number): void {
    const context = this.context;
    const height = this.height;
    const toY = (value: number): number => height - 1 - Math.min(Math.max(value / this.top, 0), 1) * (height - 3);
    // Runs of readings, broken wherever one is missing.
    const runs: [number, number][][] = [];
    let run: [number, number][] = [];
    const count = Math.min(line.values.length, this.span + 1);
    for (let age = count - 1; age >= 0; age -= 1) {
      const value = line.values[line.values.length - 1 - age];
      if (value === null || value === undefined || !Number.isFinite(value)) {
        if (run.length > 0) runs.push(run);
        run = [];
        continue;
      }
      run.push([stripWidth - age * step, toY(value)]);
    }
    if (run.length > 0) runs.push(run);

    context.strokeStyle = line.color;
    context.fillStyle = line.color;
    context.lineWidth = 1.75;
    context.lineJoin = "round";
    context.setLineDash(line.dashed === true ? [5, 3] : []);
    for (const points of runs) {
      const first = points[0];
      const last = points[points.length - 1];
      if (first === undefined || last === undefined) continue;
      if (points.length === 1) {
        context.beginPath();
        context.arc(first[0], first[1], 1.5, 0, Math.PI * 2);
        context.fill();
        continue;
      }
      context.beginPath();
      context.moveTo(first[0], first[1]);
      for (const [x, y] of points.slice(1)) context.lineTo(x, y);
      if (line.fill === true) {
        context.save();
        context.lineTo(last[0], height);
        context.lineTo(first[0], height);
        context.closePath();
        context.globalAlpha = 0.2;
        context.fill();
        context.restore();
        context.beginPath();
        context.moveTo(first[0], first[1]);
        for (const [x, y] of points.slice(1)) context.lineTo(x, y);
      }
      context.stroke();
    }
  }

  private slide(): void {
    this.animation?.cancel();
    this.animation = null;
    const end = `translateX(${-this.step()}px)`;
    if (reducedMotion.matches || !this.slides) {
      this.canvas.style.transform = end;
      return;
    }
    this.canvas.style.transform = "";
    this.animation = this.canvas.animate([{ transform: "translateX(0)" }, { transform: end }], {
      duration: this.intervalMs,
      easing: "linear",
      fill: "forwards",
    });
  }
}
