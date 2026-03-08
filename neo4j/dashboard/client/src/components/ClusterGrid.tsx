import type { Cluster } from '../types';

interface Props { rows: Cluster[]; }

export default function ClusterGrid({ rows }: Props) {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-3 p-4">
      {rows.map((c, i) => (
        <div
          key={i}
          className="bg-slate-800/50 border border-slate-700/50 rounded-lg p-4
                     hover:border-slate-600 transition"
        >
          {/* Header */}
          <div className="flex items-start justify-between mb-2">
            <div>
              <div className="text-sm font-semibold text-white">{c.market}</div>
              <div className="text-xs text-slate-500">{c.state} · {c.asset_type}</div>
            </div>
            <div className="text-right shrink-0">
              <div
                className="text-lg font-bold font-mono"
                style={{ color: scoreColor(c.avg_opportunity_score) }}
              >
                {c.avg_opportunity_score.toFixed(0)}
              </div>
              <div className="text-[10px] text-slate-600">avg score</div>
            </div>
          </div>

          {/* Metrics row */}
          <div className="grid grid-cols-3 gap-2 mt-3 border-t border-slate-700/50 pt-3">
            <Metric label="Properties"  value={c.property_count} />
            <Metric label="Value"       value={`$${(c.total_value/1_000_000).toFixed(0)}M`} />
            <Metric label="Storms"      value={c.storm_event_count} />
          </div>

          {/* Storm risk */}
          <div className="mt-3 flex items-center gap-2">
            <div className="flex-1 h-1 bg-slate-700 rounded-full overflow-hidden">
              <div
                className="h-full rounded-full"
                style={{
                  width:      `${c.market_storm_risk}%`,
                  background: `hsl(${120 - c.market_storm_risk * 1.2}, 80%, 55%)`,
                }}
              />
            </div>
            <span className="text-[10px] text-slate-500 shrink-0">
              storm risk {c.market_storm_risk}
            </span>
          </div>

          {/* Sample properties */}
          {c.sample_properties?.length > 0 && (
            <div className="mt-2 flex flex-wrap gap-1">
              {c.sample_properties.map((p, j) => (
                <span key={j} className="text-[10px] text-slate-500 bg-slate-700/40 px-1.5 py-0.5 rounded truncate max-w-[120px]">
                  {p}
                </span>
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="text-center">
      <div className="text-sm font-semibold text-white font-mono">{value}</div>
      <div className="text-[10px] text-slate-600">{label}</div>
    </div>
  );
}

function scoreColor(s: number) {
  return s >= 75 ? '#EF4444' : s >= 60 ? '#F97316' : s >= 45 ? '#EAB308' : '#3B82F6';
}
