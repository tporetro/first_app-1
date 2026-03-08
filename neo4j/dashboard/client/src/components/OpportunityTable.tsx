import type { Opportunity } from '../types';

interface Props { rows: Opportunity[]; onRowClick: (id: string) => void; }

const COND_COLOR: Record<string, string> = {
  Critical: 'text-red-400',
  Poor:     'text-orange-400',
  Fair:     'text-yellow-400',
  Good:     'text-green-400',
};

function ScoreBar({ value }: { value: number }) {
  const pct = Math.min(100, Math.max(0, value));
  const col =
    pct >= 80 ? 'bg-red-500'    :
    pct >= 65 ? 'bg-orange-500' :
    pct >= 50 ? 'bg-yellow-500' :
                'bg-blue-500';
  return (
    <div className="flex items-center gap-2">
      <div className="w-16 h-1.5 bg-slate-700 rounded-full overflow-hidden">
        <div className={`h-full ${col} rounded-full`} style={{ width: `${pct}%` }} />
      </div>
      <span className={`text-xs font-mono ${col.replace('bg-','text-')}`}>{pct.toFixed(0)}</span>
    </div>
  );
}

export default function OpportunityTable({ rows, onRowClick }: Props) {
  return (
    <div className="overflow-auto">
      <table className="w-full text-xs border-collapse">
        <thead>
          <tr className="text-slate-500 border-b border-slate-800">
            {['Property','Market','Type','Roof','Score','Value ($M)','Owner'].map(h => (
              <th key={h} className="px-3 py-2 text-left font-medium whitespace-nowrap">{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr
              key={r.id}
              onClick={() => onRowClick(r.id)}
              className="border-b border-slate-800/50 hover:bg-slate-800/40 cursor-pointer transition"
            >
              <td className="px-3 py-2 font-medium text-white max-w-[180px]">
                <div className="truncate">{r.property}</div>
                <div className="text-slate-500 text-[10px] truncate">{r.city}, {r.state}</div>
              </td>
              <td className="px-3 py-2 text-slate-300 whitespace-nowrap">{r.market}</td>
              <td className="px-3 py-2 text-slate-400 whitespace-nowrap">{r.asset_type}</td>
              <td className="px-3 py-2 whitespace-nowrap">
                <span className={COND_COLOR[r.roof_condition] ?? 'text-slate-400'}>
                  {r.roof_condition}
                </span>
                <span className="text-slate-600 ml-1">({r.roof_age}yr)</span>
              </td>
              <td className="px-3 py-2 whitespace-nowrap">
                <ScoreBar value={r.opportunity_score} />
              </td>
              <td className="px-3 py-2 text-slate-300 whitespace-nowrap font-mono">
                {r.estimated_value ? (r.estimated_value / 1_000_000).toFixed(1) : '—'}
              </td>
              <td className="px-3 py-2 text-slate-400 max-w-[140px]">
                <div className="truncate">{r.owner}</div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
