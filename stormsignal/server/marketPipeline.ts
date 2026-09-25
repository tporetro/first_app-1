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

export function normalizeMisoPricing(body: string, sourceObjectId: number, availableAt = new Date()): NormalizedPrice[] {
  const parsed = JSON.parse(body) as any;
  const nodes = parsed?.LMPData?.FiveMinLMP?.PricingNode;
  if (!Array.isArray(nodes)) throw new Error("MISO pricing response did not contain LMPData.FiveMinLMP.PricingNode");
  const interval = currentFiveMinuteInterval(availableAt);
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
  const operatingDate = availableAt.toISOString().slice(0, 10);
  const rows: NormalizedLoad[] = [];
  const addRows = (items: any[], product: "forecast" | "actual", hourKey: string, valueKey: string) => {
    for (const item of items ?? []) {
      const hour = numberValue(item?.[hourKey]);
      const megawatts = numberValue(item?.[valueKey]);
      if (hour === null || megawatts === null || hour < 1 || hour > 24) continue;
      const start = new Date(`${operatingDate}T${String(hour - 1).padStart(2, "0")}:00:00.000Z`);
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
  const parseDate = (date: string, time: string) => {
    const value = `${date} ${time}`.trim();
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  };
  return lines.slice(1).flatMap((line) => {
    const row = parseCsvLine(line);
    const externalId = [get(row, "BEGIN_YEARMONTH"), get(row, "EVENT_ID"), get(row, "EPISODE_ID"), get(row, "EVENT_TYPE")].join(":");
    const beginAt = parseDate(get(row, "BEGIN_DATE_TIME"), get(row, "BEGIN_TIME"));
    if (!beginAt || !get(row, "EVENT_TYPE")) return [];
    const endAt = parseDate(get(row, "END_DATE_TIME"), get(row, "END_TIME"));
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

export type DeltaObservation = { timestamp: Date; locationId: string; daPrice: number; rtPrice: number; stormScore: number };
export type WalkForwardDelta = DeltaObservation & { actualSpread: number; baselineSpread: number | null; predictedDelta: number | null; eligible: boolean };

export function buildWalkForwardDeltas(observations: DeltaObservation[], trainWindow = 24): WalkForwardDelta[] {
  const sorted = [...observations].sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
  return sorted.map((current, position) => {
    const history = sorted.slice(Math.max(0, position - trainWindow), position).filter((row) => row.locationId === current.locationId);
    const actualSpread = current.rtPrice - current.daPrice;
    if (history.length < Math.min(8, trainWindow)) return { ...current, actualSpread, baselineSpread: null, predictedDelta: null, eligible: false };
    const baselineSpread = history.reduce((sum, row) => sum + (row.rtPrice - row.daPrice), 0) / history.length;
    const stormAdjustment = current.stormScore * (history.reduce((sum, row) => sum + (row.rtPrice - row.daPrice) * row.stormScore, 0) / history.length);
    return { ...current, actualSpread, baselineSpread, predictedDelta: baselineSpread + stormAdjustment - baselineSpread, eligible: true };
  });
}

export function settlePaperDart(side: "long_dart" | "short_dart", quantityMw: number, daPrice: number, rtPrice: number) {
  if (![quantityMw, daPrice, rtPrice].every(Number.isFinite) || quantityMw <= 0) throw new Error("Invalid paper settlement inputs");
  const spread = rtPrice - daPrice;
  return side === "long_dart" ? quantityMw * spread : quantityMw * -spread;
}
