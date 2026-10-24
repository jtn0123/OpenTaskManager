// Figures as the interface shows them. A missing reading is "—", never zero.

export const MISSING = "—";

const UNITS = ["B", "KB", "MB", "GB", "TB"] as const;

/** `value` in the largest 1024-based unit that keeps it at 1 or more. */
function inUnits(value: number): { scaled: number; unit: string; isBytes: boolean } {
  let scaled = value;
  let index = 0;
  while (scaled >= 1024 && index < UNITS.length - 1) {
    scaled /= 1024;
    index += 1;
  }
  return { scaled, unit: UNITS[index] ?? "B", isBytes: index === 0 };
}

function usable(value: number | null | undefined): value is number {
  return value !== null && value !== undefined && Number.isFinite(value) && value >= 0;
}

/** Bytes in 1024 steps, as Windows and most Linux tools show them: three significant figures. */
export function bytes(value: number | null | undefined): string {
  if (!usable(value)) return MISSING;
  const { scaled, unit, isBytes } = inUnits(value);
  const digits = isBytes || scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2;
  return `${scaled.toFixed(digits)} ${unit}`;
}

export function rate(value: number | null | undefined): string {
  return usable(value) ? `${bytes(value)}/s` : MISSING;
}

/** An axis top, which is always round: no trailing zeros ("5 MB/s", "1.5 MB/s"). */
export function axisRate(value: number): string {
  if (!usable(value)) return MISSING;
  const { scaled, unit } = inUnits(value);
  return `${Number(scaled.toFixed(2))} ${unit}/s`;
}

/** One decimal under 10%, whole numbers above. */
export function percent(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return MISSING;
  const clamped = Math.max(0, value);
  return `${clamped < 10 ? clamped.toFixed(1) : clamped.toFixed(0)}%`;
}
