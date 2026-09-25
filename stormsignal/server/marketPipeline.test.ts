import { describe, expect, it } from "vitest";
import { buildWalkForwardDeltas, normalizeMisoLoad, normalizeMisoPricing, settlePaperDart } from "./marketPipeline";

describe("market pipeline", () => {
  it("normalizes the verified MISO pricing response shape", () => {
    const body = JSON.stringify({ LMPData: { FiveMinLMP: { PricingNode: [{ name: "NODE.A", region: "North", LMP: "42.5" }, { name: "NODE.B", LMP: "bad" }] } } });
    const rows = normalizeMisoPricing(body, 9, new Date("2026-09-24T16:00:00Z"));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ sourceObjectId: 9, locationId: "NODE.A", product: "rt_preliminary", price: 42.5 });
  });

  it("normalizes actual and forecast load rows", () => {
    const body = JSON.stringify({ LoadInfo: { ClearedMW: [{ Hour: "1", Value: "70000" }], MediumTermLoadForecast: [{ HourEnding: "1", LoadForecast: "71000" }] } });
    const rows = normalizeMisoLoad(body, 4, new Date("2026-09-24T16:00:00Z"));
    expect(rows.map((row) => row.product)).toEqual(["actual", "forecast"]);
    expect(rows.map((row) => row.megawatts)).toEqual([70000, 71000]);
  });

  it("does not produce a walk-forward prediction before enough history exists", () => {
    const observations = Array.from({ length: 10 }, (_, index) => ({ timestamp: new Date(Date.UTC(2026, 0, 1, index)), locationId: "A", daPrice: 20, rtPrice: 25 + index, stormScore: 0 }));
    const results = buildWalkForwardDeltas(observations, 8);
    expect(results.slice(0, 7).every((row) => row.eligible === false)).toBe(true);
    expect(results[8]?.eligible).toBe(true);
  });

  it("settles long and short DART paper positions with opposite signs", () => {
    expect(settlePaperDart("long_dart", 10, 20, 25)).toBe(50);
    expect(settlePaperDart("short_dart", 10, 20, 25)).toBe(-50);
  });
});
