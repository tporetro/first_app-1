import { createHash } from "node:crypto";

export type NormalizedPrice = {
  sourceObjectId: number;
  intervalStartUtc: Date;
  intervalEndUtc: Date;
  locationId: string;
  locationType: string;
  product: "rt_preliminary" | "rt_final" | "da_exante" | "da_expost";
  price: number;
  availableAt: Date;
};

export type NormalizedLoad = {
  sourceObjectId: number;
  intervalStartUtc: Date;
  intervalEndUtc: Date;
  areaId: string;
  product: "forecast" | "actual";
  megawatts: number;
  availableAt: Date;
};

function numberValue(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : Number(String(value ?? "").replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function currentFiveMinuteInterval(now: Date) {
  const start = new Date(now);
  start.setUTCSeconds(0, 0);
  start.setUTCMinutes(Math.floor(start.getUTCMinutes() / 5) * 5);
  return { start, end: new Date(start.getTime() + 5 * 60_000) };
}

// MISO publishes on Eastern Standard Time all year (UTC-5, no daylight saving).
const MISO_UTC_OFFSET_HOURS = -5;
const MONTHS: Record<string, number> = { JAN: 1, FEB: 2, MAR: 3, APR: 4, MAY: 5, JUN: 6, JUL: 7, AUG: 8, SEP: 9, OCT: 10, NOV: 11, DEC: 12 };

/** Converts a wall-clock time at a fixed UTC offset to a UTC Date. */
function fromFixedOffset(year: number, month: number, day: number, hour: number, minute: number, offsetHours: number) {
  return new Date(Date.UTC(year, month - 1, day, hour - offsetHours, minute));
}

/** The MISO operating date (EST) that contains the given instant, as YYYY-MM-DD. */
export function misoOperatingDate(at: Date) {
  return new Date(at.getTime() + MISO_UTC_OFFSET_HOURS * 3_600_000).toISOString().slice(0, 10);
}

/**
 * Parses a MISO RefId such as "24-Sep-2026 - Interval 11:05 EST" into its
 * operating date and interval time. Returns null for any other shape.
 */
export function parseMisoRefId(refId: unknown): { operatingDate: string; hour: number; minute: number } | null {
  const match = /^(\d{1,2})-([A-Za-z]{3})-(\d{4})\s*-\s*Interval\s+(\d{1,2}):(\d{2})\s+EST$/.exec(String(refId ?? "").trim());
  if (!match) return null;
  const month = MONTHS[match[2].toUpperCase()];
  if (!month) return null;
  const operatingDate = `${match[3]}-${String(month).padStart(2, "0")}-${match[1].padStart(2, "0")}`;
  return { operatingDate, hour: Number(match[4]), minute: Number(match[5]) };
}

export function normalizeMisoPricing(body: string, sourceObjectId: number, availableAt = new Date()): NormalizedPrice[] {
  const parsed = JSON.parse(body) as any;
  const nodes = parsed?.LMPData?.FiveMinLMP?.PricingNode;
  if (!Array.isArray(nodes)) throw new Error("MISO pricing response did not contain LMPData.FiveMinLMP.PricingNode");
  // Label rows with the interval MISO reports, not the time we fetched them.
  // RefId intervals are treated as interval-ending times. Without a RefId we
  // fall back to the fetch-time bucket.
  const ref = parseMisoRefId(parsed?.LMPData?.RefId);
  let interval = currentFiveMinuteInterval(availableAt);
  if (ref) {
    const [year, month, day] = ref.operatingDate.split("-").map(Number);
    const end = fromFixedOffset(year, month, day, ref.hour, ref.minute, MISO_UTC_OFFSET_HOURS);
    interval = { start: new Date(end.getTime() - 5 * 60_000), end };
  }
  return nodes.flatMap((node: any) => {
    const locationId = String(node?.name ?? "").trim();
    const price = numberValue(node?.LMP);
    if (!locationId || price === null) return [];
    return [{ sourceObjectId, intervalStartUtc: interval.start, intervalEndUtc: interval.end, locationId, locationType: "pnode", product: "rt_preliminary" as const, price, availableAt }];
  });
}

export function normalizeMisoLoad(body: string, sourceObjectId: number, availableAt = new Date()): NormalizedLoad[] {
  const parsed = JSON.parse(body) as any;
  const loadInfo = parsed?.LoadInfo;
  if (!loadInfo) throw new Error("MISO load response did not contain LoadInfo");
  // Hours are hour-ending on the MISO operating day (EST). Prefer the date in
  // the response's RefId; otherwise use the EST date at fetch time.
  const operatingDate = parseMisoRefId(loadInfo.RefId)?.operatingDate ?? misoOperatingDate(availableAt);
  const [year, month, day] = operatingDate.split("-").map(Number);
  const rows: NormalizedLoad[] = [];
  const addRows = (items: any[], product: "forecast" | "actual", hourKey: string, valueKey: string) => {
    for (const item of items ?? []) {
      const hour = numberValue(item?.[hourKey]);
      const megawatts = numberValue(item?.[valueKey]);
      if (hour === null || megawatts === null || hour < 1 || hour > 24) continue;
      const start = fromFixedOffset(year, month, day, hour - 1, 0, MISO_UTC_OFFSET_HOURS);
      rows.push({ sourceObjectId, intervalStartUtc: start, intervalEndUtc: new Date(start.getTime() + 60 * 60_000), areaId: "MISO", product, megawatts, availableAt });
    }
  };
  addRows(loadInfo.ClearedMW, "actual", "Hour", "Value");
  addRows(loadInfo.MediumTermLoadForecast, "forecast", "HourEnding", "LoadForecast");
  return rows;
}

function parseCsvLine(line: string): string[] {
  const values: string[] = [];
  let current = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"' && line[i + 1] === '"' && quoted) { current += '"'; i += 1; continue; }
    if (char === '"') { quoted = !quoted; continue; }
    if (char === "," && !quoted) { values.push(current); current = ""; continue; }
    current += char;
  }
  values.push(current);
  return values;
}

// Standard-time UTC offsets for the zone codes used in CZ_TIMEZONE. The
// numeric suffix in values like "CST-6" is ignored in favour of this table
// because some codes (e.g. "GST10") carry it without a sign.
const NOAA_ZONE_OFFSETS: Record<string, number> = { AST: -4, EST: -5, CST: -6, MST: -7, PST: -8, AKST: -9, HST: -10, SST: -11, GST: 10 };

export function noaaUtcOffsetHours(zone: string): number | null {
  const code = /^([A-Z]+)/.exec(zone.trim().toUpperCase())?.[1];
  return code && code in NOAA_ZONE_OFFSETS ? NOAA_ZONE_OFFSETS[code] : null;
}

export type NormalizedStorm = {
  sourceObjectId: number;
  externalId: string;
  eventType: string;
  beginAt: Date;
  endAt: Date | null;
  state: string | null;
  county: string | null;
  magnitude: number | null;
  magnitudeUnit: string | null;
  latitude: number | null;
  longitude: number | null;
  damageProperty: number | null;
  dataAvailableAt: Date;
};

export function normalizeNoaaStormCsv(csv: string, sourceObjectId: number, availableAt = new Date()): NormalizedStorm[] {
  const lines = csv.split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  const header = parseCsvLine(lines[0]).map((field) => field.trim());
  const index = (name: string) => header.indexOf(name);
  const get = (row: string[], name: string) => row[index(name)] ?? "";
  // Storm Events times are local standard time for the county or zone, given
  // in CZ_TIMEZONE (e.g. "CST-6"). Build the instant from BEGIN_YEARMONTH,
  // BEGIN_DAY and BEGIN_TIME (HHMM) plus that offset instead of letting the
  // server's own time zone interpret the text.
  const parseDate = (row: string[], prefix: "BEGIN" | "END") => {
    const offset = noaaUtcOffsetHours(get(row, "CZ_TIMEZONE"));
    const yearMonth = get(row, `${prefix}_YEARMONTH`).trim();
    const day = Number(get(row, `${prefix}_DAY`));
    const hhmm = get(row, `${prefix}_TIME`).trim().padStart(4, "0");
    if (offset === null || !/^\d{6}$/.test(yearMonth) || !Number.isInteger(day) || !/^\d{4}$/.test(hhmm)) return null;
    const parsed = fromFixedOffset(Number(yearMonth.slice(0, 4)), Number(yearMonth.slice(4)), day, Number(hhmm.slice(0, 2)), Number(hhmm.slice(2)), offset);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  };
  return lines.slice(1).flatMap((line) => {
    const row = parseCsvLine(line);
    const externalId = [get(row, "BEGIN_YEARMONTH"), get(row, "EVENT_ID"), get(row, "EPISODE_ID"), get(row, "EVENT_TYPE")].join(":");
    const beginAt = parseDate(row, "BEGIN");
    if (!beginAt || !get(row, "EVENT_TYPE")) return [];
    const endAt = parseDate(row, "END");
    return [{
      sourceObjectId,
      externalId: externalId || createHash("sha256").update(line).digest("hex"),
      eventType: get(row, "EVENT_TYPE"),
      beginAt,
      endAt,
      state: get(row, "STATE") || null,
      county: get(row, "CZ_NAME") || null,
      magnitude: numberValue(get(row, "MAGNITUDE")),
      magnitudeUnit: get(row, "MAGNITUDE_TYPE") || null,
      latitude: numberValue(get(row, "BEGIN_LAT")),
      longitude: numberValue(get(row, "BEGIN_LON")),
      damageProperty: numberValue(get(row, "DAMAGE_PROPERTY")),
      dataAvailableAt: availableAt,
    }];
  });
}

export type DeltaObservation = {
  /** Start of the hourly interval, UTC. */
  timestamp: Date;
  locationId: string;
  daPrice: number;
  rtPrice: number;
  /** Storm score as known at the day-ahead bid deadline for this interval. */
  stormScore: number;
  /** When this interval's real-time price was published. Defaults to interval end. */
  availableAt?: Date;
};
export type WalkForwardDelta = DeltaObservation & {
  actualSpread: number;
  baselineSpread: number | null;
  /** Storm-driven adjustment to the baseline RT − DA spread. */
  predictedDelta: number | null;
  /** baselineSpread + predictedDelta. */
  predictedSpread: number | null;
  decisionAt: Date;
  eligible: boolean;
};

// MISO's day-ahead market closes at 10:30 EST on the day before the operating day.
const DA_DEADLINE_HOUR = 10;
const DA_DEADLINE_MINUTE = 30;

/** The day-ahead bid deadline for the MISO operating day containing `intervalStart`. */
export function dayAheadDeadline(intervalStart: Date) {
  const [year, month, day] = misoOperatingDate(intervalStart).split("-").map(Number);
  return fromFixedOffset(year, month, day - 1, DA_DEADLINE_HOUR, DA_DEADLINE_MINUTE, MISO_UTC_OFFSET_HOURS);
}

/**
 * Walk-forward DART predictions that only use information a trader would have
 * when submitting a virtual bid. For each interval, history is the same
 * location's most recent `trainWindow` intervals whose real-time price was
 * published by the day-ahead deadline.
 */
export function buildWalkForwardDeltas(observations: DeltaObservation[], trainWindow = 24): WalkForwardDelta[] {
  const byLocation = new Map<string, DeltaObservation[]>();
  for (const row of observations) {
    const list = byLocation.get(row.locationId) ?? [];
    list.push(row);
    byLocation.set(row.locationId, list);
  }
  for (const list of Array.from(byLocation.values())) list.sort((a, b) => availableTime(a) - availableTime(b));

  const sorted = [...observations].sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
  return sorted.map((current) => {
    const actualSpread = current.rtPrice - current.daPrice;
    const decisionAt = dayAheadDeadline(current.timestamp);
    const known = (byLocation.get(current.locationId) ?? []).filter((row) => availableTime(row) <= decisionAt.getTime());
    const history = known.slice(Math.max(0, known.length - trainWindow));
    if (history.length < Math.min(8, trainWindow)) {
      return { ...current, actualSpread, baselineSpread: null, predictedDelta: null, predictedSpread: null, decisionAt, eligible: false };
    }
    const spreads = history.map((row) => row.rtPrice - row.daPrice);
    const baselineSpread = spreads.reduce((sum, value) => sum + value, 0) / spreads.length;
    // Least-squares slope of (spread − baseline) on storm score, through the origin.
    const scoreSquares = history.reduce((sum, row) => sum + row.stormScore * row.stormScore, 0);
    const beta = scoreSquares > 0 ? history.reduce((sum, row, i) => sum + (spreads[i] - baselineSpread) * row.stormScore, 0) / scoreSquares : 0;
    const predictedDelta = beta * current.stormScore;
    return { ...current, actualSpread, baselineSpread, predictedDelta, predictedSpread: baselineSpread + predictedDelta, decisionAt, eligible: true };
  });
}

function availableTime(row: DeltaObservation) {
  return (row.availableAt ?? new Date(row.timestamp.getTime() + 60 * 60_000)).getTime();
}

export function settlePaperDart(side: "long_dart" | "short_dart", quantityMw: number, daPrice: number, rtPrice: number) {
  if (![quantityMw, daPrice, rtPrice].every(Number.isFinite) || quantityMw <= 0) throw new Error("Invalid paper settlement inputs");
  const spread = rtPrice - daPrice;
  return side === "long_dart" ? quantityMw * spread : quantityMw * -spread;
}
