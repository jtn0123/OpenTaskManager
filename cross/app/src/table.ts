// The process table. Only the rows in view exist as elements, reused as it
// scrolls, so hundreds of processes cost what a screenful does. A row is
// selected by PID and start time, so a reused PID never inherits the selection.

import type { ProcessKey } from "./bindings/ProcessKey";
import type { ProcessRow } from "./bindings/ProcessRow";

export interface Column {
  readonly id: string;
  readonly title: string;
  readonly numeric: boolean;
  /** Sorting starts highest first for figures, A–Z for text. */
  readonly sortValue: (row: ProcessRow) => number | string | null;
  readonly text: (row: ProcessRow) => string;
}

const ROW_HEIGHT = 24;
const OVERSCAN = 8;
const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

function sameKey(a: ProcessKey | null, b: ProcessKey): boolean {
  return a !== null && a.pid === b.pid && a.startTime === b.startTime;
}

export class ProcessTable {
  private readonly columns: readonly Column[];
  private readonly header: HTMLDivElement;
  private readonly body: HTMLDivElement;
  private readonly spacer: HTMLDivElement;
  private readonly pool: HTMLDivElement[] = [];
  private rows: readonly ProcessRow[] = [];
  private shown: ProcessRow[] = [];
  private sortColumn: Column;
  private descending = true;
  private query = "";
  private selected: ProcessKey | null = null;
  /** Called after each update with how many rows show and how many there are. */
  onCount: (shown: number, total: number) => void = () => {};

  constructor(host: HTMLElement, columns: readonly Column[], sortBy: string) {
    this.columns = columns;
    const initial = columns.find((column) => column.id === sortBy) ?? columns[0];
    if (initial === undefined) throw new Error("A table needs at least one column.");
    this.sortColumn = initial;
    host.style.setProperty("--columns", String(columns.length));

    this.header = document.createElement("div");
    this.header.className = "table-row table-header";
    this.header.setAttribute("role", "row");
    for (const column of columns) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = column.numeric ? "cell numeric" : "cell";
      button.dataset["column"] = column.id;
      button.setAttribute("role", "columnheader");
      button.textContent = column.title;
      button.addEventListener("click", () => this.sortBy(column));
      this.header.append(button);
    }

    this.body = document.createElement("div");
    this.body.className = "table-body";
    this.body.tabIndex = 0;
    this.body.setAttribute("role", "rowgroup");
    this.spacer = document.createElement("div");
    this.spacer.className = "table-spacer";
    this.body.append(this.spacer);
    this.body.addEventListener("scroll", () => this.render(), { passive: true });
    this.body.addEventListener("click", (event) => this.click(event));
    this.body.addEventListener("keydown", (event) => this.key(event));
    new ResizeObserver(() => this.render()).observe(this.body);

    const table = document.createElement("div");
    table.className = "table";
    table.setAttribute("role", "table");
    table.setAttribute("aria-label", "Processes");
    table.append(this.header, this.body);
    host.append(table);
    this.markSort();
  }

  update(rows: readonly ProcessRow[]): void {
    this.rows = rows;
    this.arrange();
  }

  search(query: string): void {
    this.query = query.trim().toLowerCase();
    this.arrange();
  }

  private sortBy(column: Column): void {
    this.descending = this.sortColumn === column ? !this.descending : column.numeric;
    this.sortColumn = column;
    this.markSort();
    this.arrange();
  }

  private markSort(): void {
    for (const button of this.header.querySelectorAll<HTMLButtonElement>("button")) {
      const sorted = button.dataset["column"] === this.sortColumn.id;
      button.setAttribute("aria-sort", sorted ? (this.descending ? "descending" : "ascending") : "none");
      button.classList.toggle("sorted", sorted);
    }
  }

  private matches(row: ProcessRow): boolean {
    if (this.query === "") return true;
    return (
      row.name.toLowerCase().includes(this.query) ||
      String(row.key.pid).startsWith(this.query) ||
      (row.user?.toLowerCase().includes(this.query) ?? false)
    );
  }

  /** Filters and sorts. Missing figures sort last either way; ties go by PID. */
  private arrange(): void {
    const column = this.sortColumn;
    const direction = this.descending ? -1 : 1;
    this.shown = this.rows
      .filter((row) => this.matches(row))
      .map((row) => ({ row, value: column.sortValue(row) }))
      .sort((a, b) => {
        if (a.value === null || b.value === null) {
          if (a.value === b.value) return a.row.key.pid - b.row.key.pid;
          return a.value === null ? 1 : -1;
        }
        const order =
          typeof a.value === "number" && typeof b.value === "number"
            ? a.value - b.value
            : collator.compare(String(a.value), String(b.value));
        return order !== 0 ? order * direction : a.row.key.pid - b.row.key.pid;
      })
      .map((entry) => entry.row);
    if (this.selected !== null && !this.shown.some((row) => sameKey(this.selected, row.key))) this.selected = null;
    this.spacer.style.height = `${this.shown.length * ROW_HEIGHT}px`;
    this.render();
    this.onCount(this.shown.length, this.rows.length);
  }

  private render(): void {
    const first = Math.max(0, Math.floor(this.body.scrollTop / ROW_HEIGHT) - OVERSCAN);
    const last = Math.min(this.shown.length, Math.ceil((this.body.scrollTop + this.body.clientHeight) / ROW_HEIGHT) + OVERSCAN);
    const needed = Math.max(0, last - first);
    while (this.pool.length < needed) this.pool.push(this.makeRow());
    this.pool.forEach((element, slot) => {
      const index = first + slot;
      const row = this.shown[index];
      if (slot >= needed || row === undefined) {
        element.hidden = true;
        return;
      }
      element.hidden = false;
      element.dataset["index"] = String(index);
      element.style.transform = `translateY(${index * ROW_HEIGHT}px)`;
      element.classList.toggle("odd", index % 2 === 1);
      const selected = sameKey(this.selected, row.key);
      element.classList.toggle("selected", selected);
      element.setAttribute("aria-selected", String(selected));
      this.columns.forEach((column, cellIndex) => {
        const cell = element.children[cellIndex];
        const text = column.text(row);
        if (cell !== undefined && cell.textContent !== text) cell.textContent = text;
      });
    });
  }

  private makeRow(): HTMLDivElement {
    const element = document.createElement("div");
    element.className = "table-row";
    element.setAttribute("role", "row");
    for (const column of this.columns) {
      const cell = document.createElement("div");
      cell.className = column.numeric ? "cell numeric" : "cell";
      cell.setAttribute("role", "cell");
      element.append(cell);
    }
    this.body.append(element);
    return element;
  }

  private click(event: MouseEvent): void {
    const element = (event.target as Element | null)?.closest<HTMLElement>(".table-row");
    const index = Number(element?.dataset["index"]);
    const row = this.shown[index];
    if (row === undefined) return;
    this.selected = row.key;
    this.render();
  }

  private key(event: KeyboardEvent): void {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const current = this.shown.findIndex((row) => sameKey(this.selected, row.key));
    const next = Math.min(this.shown.length - 1, Math.max(0, current + (event.key === "ArrowDown" ? 1 : -1)));
    const row = this.shown[next];
    if (row === undefined) return;
    this.selected = row.key;
    const top = next * ROW_HEIGHT;
    if (top < this.body.scrollTop) this.body.scrollTop = top;
    else if (top + ROW_HEIGHT > this.body.scrollTop + this.body.clientHeight) {
      this.body.scrollTop = top + ROW_HEIGHT - this.body.clientHeight;
    }
    this.render();
  }
}
