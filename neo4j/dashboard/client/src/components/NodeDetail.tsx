import type { GraphNode, Connection } from '../types';
import { NODE_COLORS, LINK_COLORS } from '../constants';

interface Props {
  node:        GraphNode;
  connections: Connection[];
  onClose:     () => void;
  onNavigate:  (node: GraphNode) => void;
  onStartPath: (node: GraphNode) => void;
}

function Badge({ label, color }: { label: string; color: string }) {
  return (
    <span
      className="inline-block px-1.5 py-0.5 rounded text-xs font-semibold"
      style={{ background: color + '33', color }}
    >
      {label}
    </span>
  );
}

function PropRow({ k, v }: { k: string; v: unknown }) {
  if (v === null || v === undefined || v === '') return null;
  const display =
    typeof v === 'boolean' ? (v ? 'Yes' : 'No') :
    typeof v === 'number'  ? v.toLocaleString()  :
    String(v);
  return (
    <div className="flex gap-2 py-0.5 text-xs">
      <span className="text-slate-500 shrink-0 w-32 truncate">{k}</span>
      <span className="text-slate-200 break-all">{display}</span>
    </div>
  );
}

const SKIP_KEYS = new Set(['id', 'type', 'labels', 'name', 'x', 'y', 'vx', 'vy', 'fx', 'fy']);

export default function NodeDetail({ node, connections, onClose, onNavigate, onStartPath }: Props) {
  const color   = NODE_COLORS[node.type] ?? '#94a3b8';
  const propKeys = Object.keys(node).filter(k => !SKIP_KEYS.has(k));

  const inbound  = connections.filter(c => c.direction === 'in');
  const outbound = connections.filter(c => c.direction === 'out');

  return (
    <div className="flex flex-col h-full bg-slate-900 border-l border-slate-800 overflow-hidden">
      {/* Header */}
      <div className="flex items-start gap-2 p-4 border-b border-slate-800 shrink-0">
        <div
          className="w-3 h-3 rounded-full mt-0.5 shrink-0"
          style={{ background: color, boxShadow: `0 0 6px ${color}88` }}
        />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1">
            <Badge label={node.type} color={color} />
          </div>
          <h2 className="text-sm font-semibold text-white leading-tight break-words">
            {node.name}
          </h2>
        </div>
        <button
          onClick={onClose}
          className="shrink-0 text-slate-500 hover:text-white transition text-sm w-6 h-6 flex items-center justify-center rounded hover:bg-slate-700"
        >
          ✕
        </button>
      </div>

      {/* Actions */}
      <div className="flex gap-2 px-4 py-2 border-b border-slate-800 shrink-0">
        <button
          onClick={() => onStartPath(node)}
          className="flex-1 px-2 py-1.5 rounded text-xs bg-amber-500/10 border border-amber-500/30
                     text-amber-300 hover:bg-amber-500/20 transition"
        >
          Find Path From Here
        </button>
      </div>

      {/* Properties */}
      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-4">
        <section>
          <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">
            Properties
          </h3>
          <div className="space-y-0.5">
            {propKeys.map(k => (
              <PropRow key={k} k={k} v={node[k]} />
            ))}
          </div>
        </section>

        {/* Connections */}
        {outbound.length > 0 && (
          <section>
            <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">
              Outgoing ({outbound.length})
            </h3>
            <div className="space-y-1">
              {outbound.map((c, i) => (
                <ConnectionRow key={i} c={c} onNavigate={onNavigate} />
              ))}
            </div>
          </section>
        )}

        {inbound.length > 0 && (
          <section>
            <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">
              Incoming ({inbound.length})
            </h3>
            <div className="space-y-1">
              {inbound.map((c, i) => (
                <ConnectionRow key={i} c={c} onNavigate={onNavigate} />
              ))}
            </div>
          </section>
        )}

        {connections.length === 0 && (
          <p className="text-xs text-slate-600 italic">No connections loaded. Right-click node to expand.</p>
        )}
      </div>
    </div>
  );
}

function ConnectionRow({ c, onNavigate }: { c: Connection; onNavigate: (n: GraphNode) => void }) {
  const relColor   = LINK_COLORS[c.relType] ?? LINK_COLORS.default;
  const nodeColor  = NODE_COLORS[c.neighbor.type] ?? '#94a3b8';
  const arrow      = c.direction === 'out' ? '→' : '←';

  return (
    <button
      onClick={() => onNavigate(c.neighbor)}
      className="w-full text-left flex items-center gap-2 px-2 py-1.5 rounded
                 hover:bg-slate-800 transition group"
    >
      <span className="text-slate-500 text-xs font-mono">{arrow}</span>
      <span
        className="text-xs px-1 py-0.5 rounded font-mono shrink-0"
        style={{ color: relColor, background: relColor + '1a' }}
      >
        {c.relType}
      </span>
      <span
        className="w-2 h-2 rounded-full shrink-0"
        style={{ background: nodeColor }}
      />
      <span className="text-xs text-slate-300 truncate group-hover:text-white transition">
        {c.neighbor.name}
      </span>
      <span className="text-xs text-slate-600 shrink-0">{c.neighbor.type}</span>
    </button>
  );
}
