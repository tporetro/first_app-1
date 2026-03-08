import type { NodeType } from '../types';
import type { Stats } from '../types';
import { NODE_COLORS, ALL_NODE_TYPES } from '../constants';

interface Props {
  activeFilters:   Set<NodeType>;
  onToggle:        (t: NodeType) => void;
  onClearAll:      () => void;
  onSelectAll:     () => void;
  stats:           Stats | null;
  searchQuery:     string;
  onSearchChange:  (q: string) => void;
  onSearchSubmit:  () => void;
  pathMode:        boolean;
  onTogglePathMode: () => void;
}

export default function FilterBar({
  activeFilters, onToggle, onClearAll, onSelectAll,
  stats, searchQuery, onSearchChange, onSearchSubmit,
  pathMode, onTogglePathMode,
}: Props) {
  const countFor = (label: string) =>
    stats?.nodes.find(n => n.label === label)?.count ?? 0;

  return (
    <div className="flex flex-wrap items-center gap-2 px-4 py-2 bg-slate-900 border-b border-slate-800 shrink-0">
      {/* Search */}
      <form
        onSubmit={e => { e.preventDefault(); onSearchSubmit(); }}
        className="flex items-center gap-1"
      >
        <input
          type="text"
          value={searchQuery}
          onChange={e => onSearchChange(e.target.value)}
          placeholder="Search nodes…"
          className="w-44 px-2.5 py-1 rounded bg-slate-800 border border-slate-700 text-xs text-slate-200
                     placeholder-slate-500 focus:outline-none focus:border-blue-500 transition"
        />
        <button
          type="submit"
          className="px-2 py-1 rounded bg-slate-700 text-xs text-slate-300 hover:bg-slate-600 transition"
        >
          ⌕
        </button>
      </form>

      <span className="text-slate-700 text-xs select-none">|</span>

      {/* Node type toggles */}
      <div className="flex flex-wrap gap-1">
        {ALL_NODE_TYPES.map(type => {
          const active = activeFilters.has(type);
          const color  = NODE_COLORS[type];
          const count  = countFor(type);
          return (
            <button
              key={type}
              onClick={() => onToggle(type)}
              title={`${active ? 'Hide' : 'Show'} ${type} (${count})`}
              className="flex items-center gap-1.5 px-2 py-1 rounded text-xs font-medium
                         border transition select-none"
              style={{
                borderColor: active ? color : '#334155',
                background:  active ? color + '22' : 'transparent',
                color:       active ? color : '#64748b',
              }}
            >
              <span
                className="w-2 h-2 rounded-full"
                style={{ background: active ? color : '#475569' }}
              />
              {type}
              {count > 0 && (
                <span className="opacity-60">{count}</span>
              )}
            </button>
          );
        })}
      </div>

      <span className="text-slate-700 text-xs select-none">|</span>

      {/* All / None */}
      <button
        onClick={onSelectAll}
        className="px-2 py-1 rounded text-xs text-slate-400 hover:text-white hover:bg-slate-700 transition"
      >
        All
      </button>
      <button
        onClick={onClearAll}
        className="px-2 py-1 rounded text-xs text-slate-400 hover:text-white hover:bg-slate-700 transition"
      >
        None
      </button>

      <span className="text-slate-700 text-xs select-none">|</span>

      {/* Path mode */}
      <button
        onClick={onTogglePathMode}
        className={`flex items-center gap-1.5 px-2 py-1 rounded text-xs border transition ${
          pathMode
            ? 'border-amber-500 bg-amber-500/15 text-amber-300'
            : 'border-slate-700 text-slate-400 hover:text-white hover:bg-slate-700'
        }`}
      >
        <span className={`w-2 h-2 rounded-full ${pathMode ? 'bg-amber-400 animate-pulse' : 'bg-slate-600'}`} />
        Shortest Path
      </button>

      {/* Relationship count */}
      {stats && (
        <div className="ml-auto flex items-center gap-3 text-xs text-slate-500">
          <span>{stats.relationships.reduce((a, r) => a + r.count, 0).toLocaleString()} rels</span>
          <div className="hidden md:flex gap-2">
            {stats.relationships.slice(0, 4).map(r => (
              <span key={r.type} className="text-slate-600">
                {r.type} <span className="text-slate-500">{r.count}</span>
              </span>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
