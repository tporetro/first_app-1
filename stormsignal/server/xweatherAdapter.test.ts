import { describe, expect, it } from "vitest";
import {
  alertToStormRow,
  buildXweatherUrl,
  fetchXweather,
  normalizeAlerts,
  normalizeStormCells,
  parseXweatherEnvelope,
  pollXweather,
  stormCellToStormRow,
  toSourceObject,
  xweatherCredentials,
  type XweatherSnapshot,
} from "./xweatherAdapter";

// Sample responses follow Xweather's documented envelope and field names.
const ALERTS_BODY = JSON.stringify({
  success: true,
  error: null,
  response: [{
    id: "a1b2c3",
    loc: { long: -93.6, lat: 41.6 },
    details: { type: "SV.W", name: "SEVERE THUNDERSTORM WARNING", priority: 38 },
    timestamps: { issued: 1752525000, begins: 1752525000, expires: 1752528600 },
    place: { name: "des moines", state: "ia" },
    includes: { counties: ["IAC153"] },
  }],
});

const CELLS_BODY = JSON.stringify({
  success: true,
  error: null,
  response: [{
    id: "KDMX_Q7",
    loc: { long: -93.9, lat: 41.8 },
    ob: {
      timestamp: 1752524700, radarID: "KDMX", cellID: "Q7", tvs: 0, mda: 1,
      hail: { prob: 90, probSevere: 60, maxSizeIN: 1.75 },
      movement: { dirDEG: 110, speedMPH: 45 },
    },
    traits: { rotating: true, tornado: false, severe: true },
  }],
});

const CREDS = { clientId: "id123", clientSecret: "s3cr3t-value" };
const DSM = { locationId: "MISO.DSM", latitude: 41.6, longitude: -93.6 };
const RECEIVED = new Date("2025-07-14T20:31:00Z");

function snapshot(product: "alerts" | "stormcells", body: string): XweatherSnapshot {
  return { product, locationId: "MISO.DSM", requestUrl: "", receivedAt: RECEIVED, httpStatus: 200, body, contentHash: "h" };
}

describe("xweather adapter", () => {
  it("reads credentials only when both parts are set", () => {
    expect(xweatherCredentials({ XWEATHER_CLIENT_ID: "a", XWEATHER_CLIENT_SECRET: "b" })).toEqual({ clientId: "a", clientSecret: "b" });
    expect(xweatherCredentials({ XWEATHER_CLIENT_ID: "a" })).toBeNull();
    expect(xweatherCredentials({ XWEATHER_CLIENT_ID: " ", XWEATHER_CLIENT_SECRET: "b" })).toBeNull();
  });

  it("builds alert and storm-cell URLs for a point", () => {
    expect(buildXweatherUrl("alerts", DSM, CREDS)).toBe("https://data.api.xweather.com/alerts/41.6,-93.6?client_id=id123&client_secret=s3cr3t-value");
    const cells = new URL(buildXweatherUrl("stormcells", DSM, CREDS, { stormCellRadius: "75mi" }));
    expect(cells.pathname).toBe("/stormcells/closest");
    expect(cells.searchParams.get("p")).toBe("41.6,-93.6");
    expect(cells.searchParams.get("radius")).toBe("75mi");
  });

  it("treats warn_no_data as an empty result and other errors as failures", () => {
    expect(parseXweatherEnvelope(JSON.stringify({ success: true, error: { code: "warn_no_data" }, response: [] }))).toEqual({ ok: true, items: [], noData: true });
    expect(parseXweatherEnvelope(JSON.stringify({ success: false, error: { code: "invalid_client", description: "bad" }, response: [] }))).toEqual({ ok: false, errorCode: "invalid_client", errorDescription: "bad" });
    expect(parseXweatherEnvelope("<html>")).toMatchObject({ ok: false, errorCode: "invalid_json" });
  });

  it("stamps availability when the response arrives and never keeps the secret", async () => {
    let clock = new Date("2025-07-14T20:30:00Z");
    const fetchImpl = async () => {
      clock = RECEIVED; // the response lands a minute later
      return { status: 200, text: async () => ALERTS_BODY.replace("des moines", "echo s3cr3t-value") };
    };
    const snap = await fetchXweather("alerts", DSM, { credentials: CREDS, fetchImpl, now: () => clock });
    expect(snap.receivedAt).toEqual(RECEIVED);
    expect(snap.requestUrl).toContain("client_secret=REDACTED");
    expect(JSON.stringify(snap)).not.toContain("s3cr3t-value");
    expect(toSourceObject(snap, 7)).toMatchObject({ sourceSystem: "XWEATHER", sourceProduct: "alerts", retrievedAt: RECEIVED, ingestionRunId: 7 });
  });

  it("retries rate limits, then returns the successful response", async () => {
    const statuses = [429, 503, 200];
    const waits: number[] = [];
    const fetchImpl = async () => {
      const status = statuses.shift()!;
      return { status, text: async () => (status === 200 ? ALERTS_BODY : "{}") };
    };
    const snap = await fetchXweather("alerts", DSM, { credentials: CREDS, fetchImpl, sleep: async (ms) => { waits.push(ms); } });
    expect(snap.httpStatus).toBe(200);
    expect(waits).toEqual([1000, 2000]);
  });

  it("reports network failures without leaking the secret, and keeps polling other locations", async () => {
    let calls = 0;
    const fetchImpl = async (url: string) => {
      calls += 1;
      if (url.includes("41.6")) throw new Error(`connect failed for ${url}`);
      return { status: 200, text: async () => CELLS_BODY };
    };
    const other = { locationId: "MISO.MSP", latitude: 44.97, longitude: -93.26 };
    const { snapshots, failures } = await pollXweather([DSM, other], { credentials: CREDS, fetchImpl, maxRetries: 0 });
    expect(snapshots).toHaveLength(2);
    expect(failures).toHaveLength(2);
    expect(failures[0].error).not.toContain("s3cr3t-value");
    expect(calls).toBe(4);
  });

  it("normalizes alerts into storm rows available at receipt time", () => {
    const [alert] = normalizeAlerts(snapshot("alerts", ALERTS_BODY));
    expect(alert).toMatchObject({ externalId: "xweather:alert:a1b2c3", code: "SV.W", state: "IA", counties: ["IAC153"] });
    expect(alert.expiresAt?.toISOString()).toBe("2025-07-14T21:30:00.000Z");
    const row = alertToStormRow(alert, 5)!;
    expect(row.beginAt.toISOString()).toBe("2025-07-14T20:30:00.000Z");
    expect(row.dataAvailableAt).toEqual(RECEIVED);
    expect(row.county).toBe("IAC153");
  });

  it("normalizes storm cells, one row per radar observation", () => {
    const [cell] = normalizeStormCells(snapshot("stormcells", CELLS_BODY));
    expect(cell).toMatchObject({ cellId: "Q7", radarId: "KDMX", maxHailSizeIn: 1.75, severeHailProbability: 60, rotating: true, tornadic: false, severe: true, movementSpeedMph: 45 });
    expect(cell.externalId).toBe("xweather:cell:KDMX:Q7:1752524700");
    const row = stormCellToStormRow(cell, 5)!;
    expect(row).toMatchObject({ eventType: "Storm Cell (severe)", magnitude: 1.75, magnitudeUnit: "in", dataAvailableAt: RECEIVED });
  });

  it("throws on an API error instead of returning an empty storm list", () => {
    const body = JSON.stringify({ success: false, error: { code: "invalid_client", description: "Invalid client" } });
    expect(() => normalizeAlerts(snapshot("alerts", body))).toThrow("invalid_client");
  });
});
