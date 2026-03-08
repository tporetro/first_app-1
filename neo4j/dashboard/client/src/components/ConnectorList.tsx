import type { Connector } from '../types';

interface Props { rows: Connector[]; }

function Bar({ value, max = 100, color }: { value: number; max?: number; color: string }) {
  return (
    <div className="w-12 h-1 bg-slate-700 rounded-full overflow-hidden">
      <div className="h-full rounded-full" style={{ width: `${(value/max)*100}%`, background: color }} />
    </div>
  );
}

export default function ConnectorList({ rows }: Props) {
  const maxPipeline = Math.max(...rows.map(r => r.pipeline_value), 1);

  return (
    <div className="overflow-auto">
      <table className="w-full text-xs border-collapse">
        <thead>
          <tr className="text-slate-500 border-b border-slate-800">
            {['Name','Role','Trust','Connections','Owners','Properties','Pipeline ($M)','Avg Score'].map(h => (
              <th key={h} className="px-3 py-2 text-left font-medium whitespace-nowrap">{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.id} className="border-b border-slate-800/50 hover:bg-slate-800/40 transition">
              <td className="px-3 py-2 font-medium text-white whitespace-nowrap">
                <div>{r.name}</div>
                <div className="text-slate-600 text-[10px]">{r.email}</div>
              </td>
              <td className="px-3 py-2 text-slate-400">{r.role}</td>
              <td className="px-3 py-2">
                <div className="flex items-center gap-1.5">
                  <Bar value={r.trust_score} color="#3B82F6" />
                  <span className="text-slate-300 font-mono">{r.trust_score}</span>
                </div>
              </td>
              <td className="px-3 py-2 text-slate-300 font-mono">{r.connection_count}</td>
              <td className="px-3 py-2 text-slate-300 font-mono">{r.owners_reachable}</td>
              <td className="px-3 py-2 text-slate-300 font-mono">{r.reachable_properties}</td>
              <td className="px-3 py-2">
                <div className="flex items-center gap-1.5">
                  <Bar value={r.pipeline_value} max={maxPipeline} color="#22C55E" />
                  <span className="text-slate-300 font-mono">
                    {(r.pipeline_value / 1_000_000).toFixed(1)}
                  </span>
                </div>
              </td>
              <td className="px-3 py-2">
                <span className={`font-mono ${
                  r.avg_opportunity_score >= 70 ? 'text-red-400'    :
                  r.avg_opportunity_score >= 55 ? 'text-orange-400' :
                  'text-slate-400'
                }`}>
                  {r.avg_opportunity_score}
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
