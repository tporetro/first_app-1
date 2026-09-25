import { createHash } from "node:crypto";
import type { NormalizedStorm } from "./marketPipeline";

/**
 * Xweather live storm adapter.
 *
 * Fetches active alerts and nearby storm cells for each watched location and
 * keeps every response with the time it was received. Downstream features
 * must treat `receivedAt` as the moment the information became available.
 * Never use a storm's own timestamps for that: they describe the weather, not
 * when we knew about it.
 *
 * Credentials come from XWEATHER_CLIENT_ID and XWEATHER_CLIENT_SECRET. The
 * secret is sent as a query parameter (Xweather's scheme) but is removed from
 * every URL and error message this module returns.
 */

export const XWEATHER_BASE_URL = "https://data.api.xweather.com";
export const XWEATHER_ADAPTER_VERSION = "1.0.0";

export type XweatherCredentials = { clientId: string; clientSecret: string };
export type WatchedLocation = { locationId: string; latitude: number; longitude: number };
export type XweatherProduct = "alerts" | "stormcells";

export type XweatherSnapshot = {
  product: XweatherProduct;
  locationId: string;
  /** Request URL with the client secret removed. Safe to store and log. */
  requestUrl: string;
  receivedAt: Date;
  httpStatus: number;
  body: string;
  contentHash: string;
};

export type XweatherEnvelope =
  | { ok: true; items: any[]; noData: boolean }
  | { ok: false; errorCode: string; errorDescription: string };

type FetchLike = (url: string, init?: { signal?: AbortSignal; headers?: Record<string, string> }) => Promise<{ status: number; text(): Promise<string> }>;

export type FetchOptions = {
  credentials: XweatherCredentials;
  fetchImpl?: FetchLike;
  now?: () => Date;
  timeoutMs?: number;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
  /** Search radius for storm cells, e.g. "50mi". */
  stormCellRadius?: string;
  stormCellLimit?: number;
};

export function xweatherCredentials(env: Record<string, string | undefined> = process.env): XweatherCredentials | null {
  const clientId = env.XWEATHER_CLIENT_ID?.trim();
  const clientSecret = env.XWEATHER_CLIENT_SECRET?.trim();
  return clientId && clientSecret ? { clientId, clientSecret } : null;
}

export function redactSecret(text: string, secret: string) {
  let out = text.replace(/([?&]client_secret=)[^&\s"']*/g, "$1REDACTED");
  if (secret) out = out.split(secret).join("REDACTED");
  return out;
}

export function buildXweatherUrl(product: XweatherProduct, location: WatchedLocation, credentials: XweatherCredentials, options: Pick<FetchOptions, "stormCellRadius" | "stormCellLimit"> = {}) {
  const point = `${location.latitude},${location.longitude}`;
  const url =
    product === "alerts"
      ? new URL(`/alerts/${point}`, XWEATHER_BASE_URL)
      : new URL("/stormcells/closest", XWEATHER_BASE_URL);
  if (product === "stormcells") {
    url.searchParams.set("p", point);
    url.searchParams.set("radius", options.stormCellRadius ?? "50mi");
    url.searchParams.set("limit", String(options.stormCellLimit ?? 50));
  }
  url.searchParams.set("client_id", credentials.clientId);
  url.searchParams.set("client_secret", credentials.clientSecret);
  return url.toString();
}

/** Xweather wraps results as { success, error, response }. "warn_no_data" is an empty result, not a failure. */
export function parseXweatherEnvelope(body: string): XweatherEnvelope {
  let parsed: any;
  try {
    parsed = JSON.parse(body);
  } catch {
    return { ok: false, errorCode: "invalid_json", errorDescription: "Response was not JSON" };
  }
  const code = parsed?.error?.code ? String(parsed.error.code) : null;
  if (parsed?.success === true || code === "warn_no_data") {
    const response = parsed?.response;
    const items = Array.isArray(response) ? response : response ? [response] : [];
    return { ok: true, items, noData: code === "warn_no_data" || items.length === 0 };
  }
  return { ok: false, errorCode: code ?? "unknown_error", errorDescription: String(parsed?.error?.description ?? "No description") };
}

const RETRYABLE = new Set([429, 500, 502, 503, 504]);

/** Fetches one product for one location, retrying rate limits and server errors. */
export async function fetchXweather(product: XweatherProduct, location: WatchedLocation, options: FetchOptions): Promise<XweatherSnapshot> {
  const fetchImpl = options.fetchImpl ?? (globalThis.fetch as unknown as FetchLike);
  const now = options.now ?? (() => new Date());
  const sleep = options.sleep ?? ((ms: number) => new Promise((resolve) => setTimeout(resolve, ms)));
  const maxRetries = options.maxRetries ?? 2;
  const secret = options.credentials.clientSecret;
  const url = buildXweatherUrl(product, location, options.credentials, options);
  const requestUrl = redactSecret(url, secret);

  for (let attempt = 0; ; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 20_000);
    try {
      const response = await fetchImpl(url, { signal: controller.signal, headers: { Accept: "application/json" } });
      const body = await response.text();
      // Stamp availability when the bytes arrive, not when the request started.
      const receivedAt = now();
      if (RETRYABLE.has(response.status) && attempt < maxRetries) {
        await sleep(1_000 * 2 ** attempt);
        continue;
      }
      return {
        product,
        locationId: location.locationId,
        requestUrl,
        receivedAt,
        httpStatus: response.status,
        body: redactSecret(body, secret),
        contentHash: createHash("sha256").update(body).digest("hex"),
      };
    } catch (error) {
      if (attempt < maxRetries) {
        await sleep(1_000 * 2 ** attempt);
        continue;
      }
      throw new Error(redactSecret(`Xweather ${product} request for ${location.locationId} failed: ${(error as Error).message}`, secret));
    } finally {
      clearTimeout(timer);
    }
  }
}

/** Polls alerts and storm cells for every location, one request at a time. */
export async function pollXweather(locations: WatchedLocation[], options: FetchOptions) {
  const snapshots: XweatherSnapshot[] = [];
  const failures: { locationId: string; product: XweatherProduct; error: string }[] = [];
  for (const location of locations) {
    for (const product of ["alerts", "stormcells"] as const) {
      try {
        snapshots.push(await fetchXweather(product, location, options));
      } catch (error) {
        failures.push({ locationId: location.locationId, product, error: (error as Error).message });
      }
    }
  }
  return { snapshots, failures };
}

/** Maps a snapshot to the columns of the existing source_objects table. */
export function toSourceObject(snapshot: XweatherSnapshot, ingestionRunId: number) {
  return {
    ingestionRunId,
    sourceSystem: "XWEATHER",
    sourceProduct: snapshot.product,
    retrievedAt: snapshot.receivedAt,
    contentHash: snapshot.contentHash,
    responseUri: snapshot.requestUrl,
    responseBody: snapshot.body,
    adapterVersion: XWEATHER_ADAPTER_VERSION,
  };
}

function num(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : Number(value);
  return value === null || value === undefined || value === "" || !Number.isFinite(parsed) ? null : parsed;
}

function epoch(value: unknown): Date | null {
  const seconds = num(value);
  return seconds === null ? null : new Date(seconds * 1000);
}

export type XweatherAlert = {
  externalId: string;
  code: string | null;
  name: string;
  issuedAt: Date | null;
  beginsAt: Date | null;
  expiresAt: Date | null;
  latitude: number | null;
  longitude: number | null;
  state: string | null;
  counties: string[];
  receivedAt: Date;
};

export function normalizeAlerts(snapshot: XweatherSnapshot): XweatherAlert[] {
  const envelope = parseXweatherEnvelope(snapshot.body);
  if (!envelope.ok) throw new Error(`Xweather alerts error ${envelope.errorCode}: ${envelope.errorDescription}`);
  return envelope.items.flatMap((item: any) => {
    const id = item?.id ? String(item.id) : null;
    const name = String(item?.details?.name ?? "").trim();
    if (!id || !name) return [];
    const t = item?.timestamps ?? {};
    return [{
      externalId: `xweather:alert:${id}`,
      code: item?.details?.type ? String(item.details.type) : null,
      name,
      issuedAt: epoch(t.issued),
      beginsAt: epoch(t.begins),
      expiresAt: epoch(t.expires),
      latitude: num(item?.loc?.lat),
      longitude: num(item?.loc?.long),
      state: item?.place?.state ? String(item.place.state).toUpperCase() : null,
      counties: Array.isArray(item?.includes?.counties) ? item.includes.counties.map(String) : [],
      receivedAt: snapshot.receivedAt,
    }];
  });
}

export type XweatherStormCell = {
  externalId: string;
  cellId: string;
  radarId: string | null;
  observedAt: Date | null;
  latitude: number | null;
  longitude: number | null;
  hailProbability: number | null;
  severeHailProbability: number | null;
  maxHailSizeIn: number | null;
  tornadic: boolean;
  rotating: boolean;
  severe: boolean;
  movementDirDeg: number | null;
  movementSpeedMph: number | null;
  receivedAt: Date;
};

export function normalizeStormCells(snapshot: XweatherSnapshot): XweatherStormCell[] {
  const envelope = parseXweatherEnvelope(snapshot.body);
  if (!envelope.ok) throw new Error(`Xweather stormcells error ${envelope.errorCode}: ${envelope.errorDescription}`);
  return envelope.items.flatMap((item: any) => {
    const ob = item?.ob ?? {};
    const cellId = ob.cellID ?? item?.id;
    if (!cellId) return [];
    const observedAt = epoch(ob.timestamp);
    const radarId = ob.radarID ? String(ob.radarID) : null;
    const traits = item?.traits ?? {};
    return [{
      // A cell is re-observed every radar scan; each observation is its own row.
      externalId: `xweather:cell:${radarId ?? "?"}:${cellId}:${observedAt ? observedAt.getTime() / 1000 : "?"}`,
      cellId: String(cellId),
      radarId,
      observedAt,
      latitude: num(item?.loc?.lat),
      longitude: num(item?.loc?.long),
      hailProbability: num(ob?.hail?.prob),
      severeHailProbability: num(ob?.hail?.probSevere),
      maxHailSizeIn: num(ob?.hail?.maxSizeIN),
      tornadic: Boolean(traits.tornado) || Boolean(ob?.tvs),
      rotating: Boolean(traits.rotating) || Boolean(ob?.mda),
      severe: Boolean(traits.severe),
      movementDirDeg: num(ob?.movement?.dirDEG),
      movementSpeedMph: num(ob?.movement?.speedMPH),
      receivedAt: snapshot.receivedAt,
    }];
  });
}

/**
 * Converts alerts and cells to storm_events rows. `dataAvailableAt` is the
 * first time we received the item. Insert these with "ignore on duplicate"
 * (not the NOAA importer's "update on duplicate") so later polls don't move
 * that time forward.
 */
export function alertToStormRow(alert: XweatherAlert, sourceObjectId: number): NormalizedStorm | null {
  const beginAt = alert.beginsAt ?? alert.issuedAt;
  if (!beginAt) return null;
  return {
    sourceObjectId,
    externalId: alert.externalId,
    eventType: alert.name.slice(0, 64),
    beginAt,
    endAt: alert.expiresAt,
    state: alert.state,
    county: alert.counties[0] ?? null,
    magnitude: null,
    magnitudeUnit: null,
    latitude: alert.latitude,
    longitude: alert.longitude,
    damageProperty: null,
    dataAvailableAt: alert.receivedAt,
  };
}

export function stormCellToStormRow(cell: XweatherStormCell, sourceObjectId: number): NormalizedStorm | null {
  if (!cell.observedAt) return null;
  return {
    sourceObjectId,
    externalId: cell.externalId,
    eventType: cell.tornadic ? "Storm Cell (tornadic)" : cell.severe ? "Storm Cell (severe)" : "Storm Cell",
    beginAt: cell.observedAt,
    endAt: null,
    state: null,
    county: null,
    magnitude: cell.maxHailSizeIn,
    magnitudeUnit: cell.maxHailSizeIn === null ? null : "in",
    latitude: cell.latitude,
    longitude: cell.longitude,
    damageProperty: null,
    dataAvailableAt: cell.receivedAt,
  };
}
