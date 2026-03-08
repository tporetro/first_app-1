import { NODE_COLORS, ALL_NODE_TYPES, LINK_COLORS } from '../constants';

const REL_SAMPLE = ['OWNS', 'CONNECTED_TO', 'LOCATED_IN', 'AFFECTED_BY', 'PROOF_NEAR'];

export default function Legend() {
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-1.5
                    bg-slate-900/80 border-t border-slate-800 text-xs shrink-0">
      {/* Node types */}
      <span className="text-slate-600 uppercase tracking-wider text-[10px]">Nodes</span>
      {ALL_NODE_TYPES.map(type => (
        <span key={type} className="flex items-center gap-1 text-slate-400">
          <span
            className="w-2.5 h-2.5 rounded-full"
            style={{ background: NODE_COLORS[type] }}
          />
          {type}
        </span>
      ))}

      <span className="text-slate-700 select-none">|</span>

      {/* Relationship types */}
      <span className="text-slate-600 uppercase tracking-wider text-[10px]">Rels</span>
      {REL_SAMPLE.map(rel => (
        <span key={rel} className="flex items-center gap-1 text-slate-500">
          <span
            className="w-4 h-0.5 rounded"
            style={{ background: LINK_COLORS[rel] ?? LINK_COLORS.default }}
          />
          {rel}
        </span>
      ))}
    </div>
  );
}
