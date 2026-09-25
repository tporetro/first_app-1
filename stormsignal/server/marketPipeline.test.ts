import { describe, expect, it } from "vitest";
import {
  buildWalkForwardDeltas,
  dayAheadDeadline,
  normalizeMisoLoad,
  normalizeMisoPricing,
  normalizeNoaaStormCsv,
  parseMisoRefId,
  settlePaperDart,
} from "./marketPipeline";

describe("market pipeline", () => {
  it("normalizes the verified MISO pricing response shape", () => {
    const body = JSON.stringify({ LMPData: { FiveMinLMP: { PricingNode: [{ name: "NODE.A", region: "North", LMP: "42.5" }, { name: "NODE.B", LMP: "bad" }] } } });
    const rows = normalizeMisoPricing(body, 9, new Date("2026-09-24T16:00:00Z"));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ sourceObjectId: 9, locationId: "NODE.A", product: "rt_preliminary", price: 42.5 });
  });

  it("labels pricing rows with the RefId interval, not the fetch time", () => {
    const body = JSON.stringify({ LMPData: { RefId: "24-Sep-2026 - Interval 11:05 EST", FiveMinLMP: { PricingNode: [{ name: "NODE.A", LMP: "42.5" }] } } });
    // Fetched 20 minutes late.
    const [row] = normalizeMisoPricing(body, 9, new Date("2026-09-24T16:25:00Z"));
    expect(row.intervalEndUtc.toISOString()).toBe("2026-09-24T16:05:00.000Z");
    expect(row.intervalStartUtc.toISOString()).toBe("2026-09-24T16:00:00.000Z");
  });

  it("parses MISO RefIds and rejects other shapes", () => {
    expect(parseMisoRefId("4-Mar-2026 - Interval 09:40 EST")).toEqual({ operatingDate: "2026-03-04", hour: 9, minute: 40 });
    expect(parseMisoRefId("2026-03-04T09:40")).toBeNull();
    expect(parseMisoRefId(undefined)).toBeNull();
  });

  it("normalizes actual and forecast load rows", () => {
    const body = JSON.stringify({ LoadInfo: { ClearedMW: [{ Hour: "1", Value: "70000" }], MediumTermLoadForecast: [{ HourEnding: "1", LoadForecast: "71000" }] } });
    const rows = normalizeMisoLoad(body, 4, new Date("2026-09-24T16:00:00Z"));
    expect(rows.map((row) => row.product)).toEqual(["actual", "forecast"]);
    expect(rows.map((row) => row.megawatts)).toEqual([70000, 71000]);
  });

  it("places MISO hour-ending 1 at 05:00 UTC on the EST operating day", () => {
    const body = JSON.stringify({ LoadInfo: { ClearedMW: [{ Hour: "1", Value: "70000" }, { Hour: "24", Value: "65000" }] } });
    const [he1, he24] = normalizeMisoLoad(body, 4, new Date("2026-09-24T16:00:00Z"));
    expect(he1.intervalStartUtc.toISOString()).toBe("2026-09-24T05:00:00.000Z");
    expect(he24.intervalStartUtc.toISOString()).toBe("2026-09-25T04:00:00.000Z");
  });

  it("uses the EST operating date for evening fetches, when UTC has rolled over", () => {
    const body = JSON.stringify({ LoadInfo: { ClearedMW: [{ Hour: "1", Value: "70000" }] } });
    // 21:00 EST on Sep 24 is 02:00 UTC on Sep 25.
    const [row] = normalizeMisoLoad(body, 4, new Date("2026-09-25T02:00:00Z"));
    expect(row.intervalStartUtc.toISOString()).toBe("2026-09-24T05:00:00.000Z");
  });

  it("reads NOAA storm times in the zone's local standard time", () => {
    const header = "BEGIN_YEARMONTH,BEGIN_DAY,BEGIN_TIME,END_YEARMONTH,END_DAY,END_TIME,EPISODE_ID,EVENT_ID,STATE,EVENT_TYPE,CZ_NAME,CZ_TIMEZONE,BEGIN_DATE_TIME,END_DATE_TIME,MAGNITUDE,MAGNITUDE_TYPE,BEGIN_LAT,BEGIN_LON,DAMAGE_PROPERTY";
    const rows = [
      "202507,14,1530,202507,14,1645,100,200,IOWA,Thunderstorm Wind,POLK,CST-6,14-JUL-25 15:30:00,14-JUL-25 16:45:00,65,EG,41.6,-93.6,10.00K",
      "202507,14,905,202507,14,930,101,201,OHIO,Hail,FRANKLIN,EST-5,14-JUL-25 09:05:00,14-JUL-25 09:30:00,1.75,,40.0,-83.0,",
      "202507,14,905,202507,14,930,102,202,OHIO,Hail,FRANKLIN,XYZ,14-JUL-25 09:05:00,14-JUL-25 09:30:00,1.75,,40.0,-83.0,",
    ];
    const storms = normalizeNoaaStormCsv([header, ...rows].join("\n"), 1);
    expect(storms).toHaveLength(2);
    expect(storms[0].beginAt.toISOString()).toBe("2025-07-14T21:30:00.000Z");
    expect(storms[0].endAt?.toISOString()).toBe("2025-07-14T22:45:00.000Z");
    expect(storms[1].beginAt.toISOString()).toBe("2025-07-14T14:05:00.000Z");
  });

  it("sets the day-ahead deadline to 10:30 EST the day before the operating day", () => {
    // 14:00 UTC Sep 24 is 09:00 EST Sep 24, so the deadline is 10:30 EST Sep 23.
    expect(dayAheadDeadline(new Date("2026-09-24T14:00:00Z")).toISOString()).toBe("2026-09-23T15:30:00.000Z");
    // 03:00 UTC Sep 25 is still the Sep 24 operating day in EST.
    expect(dayAheadDeadline(new Date("2026-09-25T03:00:00Z")).toISOString()).toBe("2026-09-23T15:30:00.000Z");
  });

  it("only uses history published before the day-ahead deadline", () => {
    // One observation per day at 18:00 UTC. For day d, the deadline is 15:30 UTC on
    // day d-1, when day d-1's 18:00 price is not yet known, so history ends at d-2.
    const observations = Array.from({ length: 10 }, (_, index) => ({ timestamp: new Date(Date.UTC(2026, 0, 1 + index, 18)), locationId: "A", daPrice: 20, rtPrice: 25 + index, stormScore: 0 }));
    const results = buildWalkForwardDeltas(observations, 8);
    expect(results.slice(0, 9).every((row) => row.eligible === false)).toBe(true);
    expect(results[9]?.eligible).toBe(true);
    // Baseline over days 0..7: spreads 5..12.
    expect(results[9]?.baselineSpread).toBeCloseTo(8.5);
  });

  it("ignores same-day intervals that a day-ahead bid could not have seen", () => {
    const history = Array.from({ length: 8 }, (_, index) => ({ timestamp: new Date(Date.UTC(2026, 0, 1 + index, 18)), locationId: "A", daPrice: 20, rtPrice: 25, stormScore: 0 }));
    const sameDay = Array.from({ length: 12 }, (_, hour) => ({ timestamp: new Date(Date.UTC(2026, 0, 11, 6 + hour)), locationId: "A", daPrice: 20, rtPrice: 500, stormScore: 0 }));
    const target = { timestamp: new Date(Date.UTC(2026, 0, 11, 20)), locationId: "A", daPrice: 20, rtPrice: 30, stormScore: 0 };
    const result = buildWalkForwardDeltas([...history, ...sameDay, target], 24).at(-1);
    expect(result?.eligible).toBe(true);
    expect(result?.baselineSpread).toBeCloseTo(5);
  });

  it("builds history per location, not from a mixed window", () => {
    const rows = [];
    for (let day = 0; day < 10; day += 1) {
      rows.push({ timestamp: new Date(Date.UTC(2026, 0, 1 + day, 18)), locationId: "A", daPrice: 20, rtPrice: 25, stormScore: 0 });
      for (let n = 0; n < 5; n += 1) rows.push({ timestamp: new Date(Date.UTC(2026, 0, 1 + day, 18, n + 1)), locationId: `OTHER${n}`, daPrice: 20, rtPrice: 20, stormScore: 0 });
    }
    const last = buildWalkForwardDeltas(rows, 8).filter((row) => row.locationId === "A").at(-1);
    expect(last?.eligible).toBe(true);
  });

  it("predicts the storm adjustment as a regression slope times the score", () => {
    // Spread = 5 + 10 * score in history; score 2 today should predict delta ≈ 20.
    const history = Array.from({ length: 12 }, (_, index) => {
      const score = index % 2 === 0 ? 1 : -1;
      return { timestamp: new Date(Date.UTC(2026, 0, 1 + index, 18)), locationId: "A", daPrice: 20, rtPrice: 25 + 10 * score, stormScore: score };
    });
    const target = { timestamp: new Date(Date.UTC(2026, 0, 20, 18)), locationId: "A", daPrice: 20, rtPrice: 20, stormScore: 2 };
    const result = buildWalkForwardDeltas([...history, target], 24).at(-1);
    expect(result?.predictedDelta).toBeCloseTo(20);
    expect(result?.predictedSpread).toBeCloseTo(25);
  });

  it("settles long and short DART paper positions with opposite signs", () => {
    expect(settlePaperDart("long_dart", 10, 20, 25)).toBe(50);
    expect(settlePaperDart("short_dart", 10, 20, 25)).toBe(-50);
  });
});
