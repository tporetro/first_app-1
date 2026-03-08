import type { Action } from '../types';
import { URGENCY_COLORS } from '../constants';

interface Props { rows: Action[]; }

const ACTION_ICONS: Record<string, string> = {
  'inspect property':       '🔍',
  'send opportunity report': '📋',
  'contact connector':      '🤝',
  'expand market cluster':  '📍',
};

export default function ActionList({ rows }: Props) {
  // Deduplicate by property_id + action
  const seen  = new Set<string>();
  const deduped = rows.filter(r => {
    const key = `${r.action}:${r.property_id}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  return (
    <div className="divide-y divide-slate-800/60">
      {deduped.map((r, i) => {
        const urgencyCol = URGENCY_COLORS[r.urgency] ?? '#64748b';
        const icon       = ACTION_ICONS[r.action] ?? '⚡';
        return (
          <div key={i} className="flex items-start gap-3 px-4 py-3 hover:bg-slate-800/30 transition">
            {/* Urgency dot */}
            <div className="flex flex-col items-center pt-0.5 shrink-0 gap-1">
              <span
                className="w-2 h-2 rounded-full"
                style={{ background: urgencyCol, boxShadow: `0 0 4px ${urgencyCol}88` }}
              />
              <span className="text-[10px] font-semibold" style={{ color: urgencyCol }}>
                {r.urgency}
              </span>
            </div>

            {/* Content */}
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 mb-0.5">
                <span className="text-sm">{icon}</span>
                <span className="text-xs font-semibold text-white capitalize">{r.action}</span>
                <span className="text-xs text-slate-500">·</span>
                <span className="text-xs text-slate-300 truncate">{r.target_node}</span>
              </div>
              <div className="text-xs text-slate-500 mb-1 truncate">{r.reason}</div>
              <div className="flex flex-wrap gap-3 text-xs">
                <span className="text-slate-600">
                  Score: <span className="text-orange-400 font-mono">{r.opportunity_score?.toFixed(0)}</span>
                </span>
                <span className="text-slate-600">
                  Value: <span className="text-green-400 font-mono">
                    ${(r.estimated_value / 1_000_000).toFixed(1)}M
                  </span>
                </span>
                {r.owner_name && r.owner_name !== '—' && (
                  <span className="text-slate-600">
                    Owner: <span className="text-blue-400">{r.owner_name}</span>
                  </span>
                )}
              </div>
            </div>
          </div>
        );
      })}

      {deduped.length === 0 && (
        <div className="px-4 py-8 text-center text-slate-600 text-sm">
          No actions queued. Run the scoring engine to surface opportunities.
        </div>
      )}
    </div>
  );
}
