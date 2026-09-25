import crypto from "node:crypto";
import { gunzipSync } from "node:zlib";
import { and, desc, eq } from "drizzle-orm";
import { ingestionRuns, loadObservations, marketIntervals, priceObservations, sourceObjects, stormEvents } from "../drizzle/schema";
import { getDb } from "./db";
import { misoOperatingDate, normalizeMisoLoad, normalizeMisoPricing, normalizeNoaaStormCsv } from "./marketPipeline";

const ADAPTER_VERSION = "1.1.0";
const REQUEST_TIMEOUT_MS = 45_000;
const MAX_RETAINED_BODY_BYTES = 8 * 1024 * 1024;
const MISO_PUBLIC_API = "https://public-api.misoenergy.org";
const NOAA_2025_DETAILS_CSV = "https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/StormEvents_details-ftp_v1.0_d2025_c20260819.csv.gz";

type SourceConfig = { key: string; sourceSystem: "MISO" | "NOAA"; sourceProduct: string; urlEnv: string; apiKeyEnv?: string };
const SOURCE_CONFIGS: SourceConfig[] = [
  { key: "miso_pricing", sourceSystem: "MISO", sourceProduct: "pricing", urlEnv: "MISO_PRICING_ENDPOINT", apiKeyEnv: "MISO_DATA_EXCHANGE_API_KEY" },
  { key: "miso_load_generation", sourceSystem: "MISO", sourceProduct: "load_generation_interchange", urlEnv: "MISO_LOAD_GENERATION_ENDPOINT", apiKeyEnv: "MISO_DATA_EXCHANGE_API_KEY" },
  { key: "noaa_storm_events", sourceSystem: "NOAA", sourceProduct: "storm_events", urlEnv: "NOAA_STORM_EVENTS_ENDPOINT" },
];

export type SourceStatus = {
  key: string; sourceSystem: string; sourceProduct: string; configured: boolean;
  status: "not_configured" | "never_run" | "running" | "succeeded" | "failed" | "blocked";
  endpointConfigured: boolean; lastRunAt: Date | null; lastSuccessAt: Date | null;
  lastRowCount: number | null; lastError: string | null;
};
export type RefreshResult = SourceStatus & { fetched: boolean; contentHash?: string; httpStatus?: number };

function configuredValue(name: string) {
  const value = process.env[name];
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}
function endpointFor(config: SourceConfig) {
  const explicit = configuredValue(config.urlEnv);
  if (explicit) return explicit;
  if (config.key === "miso_pricing") return `${MISO_PUBLIC_API}/api/MarketPricing/GetLmpConsolidatedTable`;
  if (config.key === "miso_load_generation") return `${MISO_PUBLIC_API}/api/RealTimeTotalLoad`;
  if (config.key === "noaa_storm_events") return NOAA_2025_DETAILS_CSV;
  return null;
}
function sha256(body: string) { return crypto.createHash("sha256").update(body).digest("hex"); }
function schemaHash(body: string) {
  try {
    const parsed = JSON.parse(body);
    const sample = Array.isArray(parsed) ? parsed[0] : parsed;
    return sha256(JSON.stringify(sample && typeof sample === "object" ? Object.keys(sample).sort() : typeof sample));
  } catch { return sha256("non-json"); }
}
async function fetchWithTimeout(url: string, headers: Record<string, string>) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(url, { method: "GET", headers: { Accept: "text/csv,application/json", ...headers }, signal: controller.signal });
    const bytes = Buffer.from(await response.arrayBuffer());
    const body = url.endsWith(".gz") || response.headers.get("content-encoding") === "gzip" ? gunzipSync(bytes).toString("utf8") : bytes.toString("utf8");
    return { response, body };
  } finally { clearTimeout(timeout); }
}
async function latestRun(sourceSystem: string, sourceProduct: string) {
  const db = await getDb();
  if (!db) return undefined;
  const rows = await db.select().from(ingestionRuns).where(eq(ingestionRuns.sourceSystem, sourceSystem)).orderBy(desc(ingestionRuns.startedAt)).limit(50);
  return rows.find((row) => row.sourceProduct === sourceProduct);
}

export async function getSourceStatuses(): Promise<SourceStatus[]> {
  return Promise.all(SOURCE_CONFIGS.map(async (config) => {
    const endpoint = endpointFor(config);
    const run = await latestRun(config.sourceSystem, config.sourceProduct);
    return {
      key: config.key, sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct,
      configured: Boolean(endpoint), endpointConfigured: Boolean(endpoint), status: endpoint ? (run?.status ?? "never_run") : "not_configured",
      lastRunAt: run?.startedAt ?? null, lastSuccessAt: run?.status === "succeeded" ? run.finishedAt ?? null : null,
      lastRowCount: run?.rowCount ?? null, lastError: run?.errorMessage ?? null,
    } satisfies SourceStatus;
  }));
}

// MISO runs on Eastern Standard Time all year. "Etc/GMT+5" is the IANA name
// for fixed UTC-5 (the sign is inverted by convention).
const MISO_TIMEZONE = "Etc/GMT+5";

/** A market_intervals row for a MISO interval, dated by its EST operating day. */
function misoIntervalValues(intervalStartUtc: Date, intervalEndUtc: Date) {
  return { market: "MISO", operatingDate: misoOperatingDate(intervalStartUtc), intervalStartUtc, intervalEndUtc, timezone: MISO_TIMEZONE };
}

async function persistNormalizedMiso(db: NonNullable<Awaited<ReturnType<typeof getDb>>>, key: string, body: string, sourceObjectId: number, availableAt: Date) {
  if (key === "miso_pricing") {
    for (const row of normalizeMisoPricing(body, sourceObjectId, availableAt)) {
      const values = misoIntervalValues(row.intervalStartUtc, row.intervalEndUtc);
      // Also correct the date and zone on rows written before this fix.
      await db.insert(marketIntervals).values(values).onDuplicateKeyUpdate({ set: { intervalEndUtc: values.intervalEndUtc, operatingDate: values.operatingDate, timezone: values.timezone } });
      const interval = await db.select({ id: marketIntervals.id }).from(marketIntervals).where(and(eq(marketIntervals.market, "MISO"), eq(marketIntervals.intervalStartUtc, row.intervalStartUtc))).limit(1);
      if (interval[0]) await db.insert(priceObservations).values({ sourceObjectId, marketIntervalId: interval[0].id, locationId: row.locationId, locationType: row.locationType, product: row.product, price: row.price, availableAt: row.availableAt }).onDuplicateKeyUpdate({ set: { price: row.price, availableAt: row.availableAt } });
    }
  }
  if (key === "miso_load_generation") {
    for (const row of normalizeMisoLoad(body, sourceObjectId, availableAt)) {
      const values = misoIntervalValues(row.intervalStartUtc, row.intervalEndUtc);
      // Also correct the date and zone on rows written before this fix.
      await db.insert(marketIntervals).values(values).onDuplicateKeyUpdate({ set: { intervalEndUtc: values.intervalEndUtc, operatingDate: values.operatingDate, timezone: values.timezone } });
      const interval = await db.select({ id: marketIntervals.id }).from(marketIntervals).where(and(eq(marketIntervals.market, "MISO"), eq(marketIntervals.intervalStartUtc, row.intervalStartUtc))).limit(1);
      if (interval[0]) await db.insert(loadObservations).values({ sourceObjectId, marketIntervalId: interval[0].id, areaId: row.areaId, product: row.product, megawatts: row.megawatts, availableAt: row.availableAt });
    }
  }
}

async function persistNormalizedNoaa(db: NonNullable<Awaited<ReturnType<typeof getDb>>>, body: string, sourceObjectId: number, availableAt: Date) {
  for (const row of normalizeNoaaStormCsv(body, sourceObjectId, availableAt)) {
    await db.insert(stormEvents).values(row).onDuplicateKeyUpdate({ set: { sourceObjectId, dataAvailableAt: availableAt } });
  }
}

export async function refreshConfiguredSources(onlyKeys?: string[]): Promise<RefreshResult[]> {
  const db = await getDb();
  const results: RefreshResult[] = [];
  const configs = onlyKeys?.length ? SOURCE_CONFIGS.filter((config) => onlyKeys.includes(config.key)) : SOURCE_CONFIGS;
  for (const config of configs) {
    const endpoint = endpointFor(config);
    if (!endpoint) {
      results.push({ key: config.key, sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct, configured: false, endpointConfigured: false, status: "not_configured", lastRunAt: null, lastSuccessAt: null, lastRowCount: null, lastError: `Missing ${config.urlEnv}`, fetched: false });
      continue;
    }
    if (!db) {
      results.push({ key: config.key, sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct, configured: true, endpointConfigured: true, status: "blocked", lastRunAt: null, lastSuccessAt: null, lastRowCount: null, lastError: "DATABASE_URL is not available; raw source retention is blocked.", fetched: false });
      continue;
    }
    const startedAt = new Date();
    const runInsert = await db.insert(ingestionRuns).values({ sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct, status: "running", startedAt, rowCount: 0 });
    let runId = Number((runInsert as { insertId?: number }).insertId ?? 0);
    if (!runId) {
      const latest = await db.select({ id: ingestionRuns.id }).from(ingestionRuns).where(and(eq(ingestionRuns.sourceSystem, config.sourceSystem), eq(ingestionRuns.sourceProduct, config.sourceProduct), eq(ingestionRuns.status, "running"))).orderBy(desc(ingestionRuns.startedAt)).limit(1);
      runId = latest[0]?.id ?? 0;
    }
    try {
      const headers: Record<string, string> = {};
      const apiKey = config.apiKeyEnv ? configuredValue(config.apiKeyEnv) : null;
      if (apiKey) headers["Ocp-Apim-Subscription-Key"] = apiKey;
      const { response, body } = await fetchWithTimeout(endpoint, headers);
      if (!response.ok) throw new Error(`${config.sourceSystem} ${config.sourceProduct} returned HTTP ${response.status}`);
      const parsed = config.sourceSystem === "NOAA" ? null : JSON.parse(body);
      const rowCount = config.key === "noaa_storm_events" ? normalizeNoaaStormCsv(body, 0, startedAt).length : Array.isArray(parsed) ? parsed.length : config.key === "miso_pricing" ? (parsed?.LMPData?.FiveMinLMP?.PricingNode?.length ?? 0) : config.key === "miso_load_generation" ? ((parsed?.LoadInfo?.ClearedMW?.length ?? 0) + (parsed?.LoadInfo?.MediumTermLoadForecast?.length ?? 0)) : 1;
      const hash = sha256(body);
      const retainedBody = Buffer.byteLength(body, "utf8") <= MAX_RETAINED_BODY_BYTES ? body : null;
      const sourceInsert = await db.insert(sourceObjects).values({ ingestionRunId: runId, sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct, retrievedAt: startedAt, contentHash: hash, schemaHash: schemaHash(body), responseUri: endpoint, responseBody: retainedBody, adapterVersion: ADAPTER_VERSION }).onDuplicateKeyUpdate({ set: { retrievedAt: startedAt } });
      let sourceObjectId = Number((sourceInsert as { insertId?: number }).insertId ?? 0);
      if (!sourceObjectId) {
        const existing = await db.select({ id: sourceObjects.id }).from(sourceObjects).where(and(eq(sourceObjects.sourceSystem, config.sourceSystem), eq(sourceObjects.sourceProduct, config.sourceProduct), eq(sourceObjects.contentHash, hash))).limit(1);
        sourceObjectId = existing[0]?.id ?? 0;
      }
      if (sourceObjectId && retainedBody && config.sourceSystem === "MISO") await persistNormalizedMiso(db, config.key, retainedBody, sourceObjectId, startedAt);
      if (sourceObjectId && config.sourceSystem === "NOAA") await persistNormalizedNoaa(db, body, sourceObjectId, startedAt);
      await db.update(ingestionRuns).set({ status: "succeeded", finishedAt: new Date(), rowCount, errorMessage: retainedBody === null ? `Response exceeded ${MAX_RETAINED_BODY_BYTES} bytes; metadata retained without body.` : null }).where(eq(ingestionRuns.id, runId));
      results.push({ key: config.key, sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct, configured: true, endpointConfigured: true, status: "succeeded", lastRunAt: startedAt, lastSuccessAt: new Date(), lastRowCount: rowCount, lastError: retainedBody === null ? "Large response body was not retained." : null, fetched: true, contentHash: hash, httpStatus: response.status });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await db.update(ingestionRuns).set({ status: "failed", finishedAt: new Date(), errorMessage: message }).where(eq(ingestionRuns.id, runId));
      results.push({ key: config.key, sourceSystem: config.sourceSystem, sourceProduct: config.sourceProduct, configured: true, endpointConfigured: true, status: "failed", lastRunAt: startedAt, lastSuccessAt: null, lastRowCount: 0, lastError: message, fetched: false });
    }
  }
  return results;
}
