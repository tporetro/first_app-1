import type { Pipeline } from '../types';
import { TIER_COLORS } from '../constants';

interface Props { data: Pipeline; }

export default function PipelineView({ data }: Props) {
  const { tiers, funnel } = data;
  const maxCount = Math.max(...tiers.map(t => t.property_count), 1);

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 p-4">
      {/* Tier bars */}
      <div>
        <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3">
          Opportunity Tiers
        </h3>
        <div className="space-y-2">
          {tiers.map(t => {
            const color = TIER_COLORS[t.tier] ?? '#475569';
            const pct   = (t.property_count / maxCount) * 100;
            return (
              <div key={t.tier} className="flex items-center gap-3">
                <span
                  className="w-14 text-xs font-semibold shrink-0"
                  style={{ color }}
                >
                  {t.tier}
                </span>
                <div className="flex-1 h-6 bg-slate-800 rounded overflow-hidden">
                  <div
                    className="h-full rounded flex items-center px-2 transition-all"
                    style={{ width: `${pct}%`, background: color + '44', borderLeft: `3px solid ${color}` }}
                  >
                    <span className="text-xs font-mono text-white/80">{t.property_count}</span>
                  </div>
                </div>
                <span className="text-xs text-slate-500 font-mono w-20 shrink-0 text-right">
                  ${(t.total_value / 1_000_000).toFixed(0)}M
                </span>
                <span className="text-xs text-slate-600 font-mono w-10 shrink-0">
                  ⌀{t.avg_score}
                </span>
              </div>
            );
          })}
        </div>
      </div>

      {/* Funnel metrics */}
      <div>
        <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3">
          Funnel Metrics
        </h3>
        <div className="grid grid-cols-2 gap-3">
          {[
            { label: 'Views',       value: funnel.teaser_views,          color: '#3B82F6' },
            { label: 'Reports',     value: funnel.reports_generated,     color: '#A855F7' },
            { label: 'Inspections', value: funnel.inspections_requested, color: '#F97316' },
            { label: 'Activation',  value: `${(funnel.activation_rate * 100).toFixed(0)}%`, color: '#22C55E' },
          ].map(m => (
            <div
              key={m.label}
              className="bg-slate-800/60 rounded-lg p-3 border border-slate-700/50"
            >
              <div className="text-2xl font-bold font-mono" style={{ color: m.color }}>
                {m.value}
              </div>
              <div className="text-xs text-slate-500 mt-0.5">{m.label}</div>
            </div>
          ))}
        </div>

        {/* Conversion flow */}
        <div className="mt-4 flex items-center gap-1 text-xs">
          <span className="text-blue-400 font-mono">{funnel.teaser_views}</span>
          <span className="text-slate-600">views →</span>
          <span className="text-purple-400 font-mono">{funnel.reports_generated}</span>
          <span className="text-slate-600">reports →</span>
          <span className="text-orange-400 font-mono">{funnel.inspections_requested}</span>
          <span className="text-slate-600">inspections</span>
          <span className="ml-auto text-green-400 font-mono">
            {(funnel.activation_rate * 100).toFixed(0)}% activation
          </span>
        </div>
      </div>
    </div>
  );
}
