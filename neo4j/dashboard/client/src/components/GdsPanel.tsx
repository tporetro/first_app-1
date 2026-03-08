import { useState, useCallback } from 'react';
import type {
  BetweennessResult, PageRankResult, CommunityResult,
  SimilarityResult, GdsWriteResult, GraphNode,
} from '../types';
import {
  fetchGdsBetweenness, fetchGdsPageRank, fetchGdsCommunities,
  fetchGdsSimilarity, fetchGdsPath, writeGdsScores,
} from '../api';
import { NODE_COLORS } from '../constants';

// ── tiny shared components ─────────────────────────────────────

function GdsSection({
  title, subtitle, children,
}: { title: string; subtitle: string; children: React.ReactNode }) {
  return (
    <section className="border border-slate-800 rounded-lg overflow-hidden">
      <div className="px-4 py-3 bg-slate-800/40 border-b border-slate-800">
        <h3 className="text-sm font-semibold text-white">{title}</h3>
        <p className="text-xs text-slate-500 mt-0.5">{subtitle}</p>
      </div>
      <div className="p-4">{children}</div>
    </section>
  );
}

function RunBtn({ onClick, loading, label }: { onClick: () => void; loading: boolean; label: string }) {
  return (
    <button
      onClick={onClick}
      disabled={loading}
      className="px-3 py-1.5 rounded text-xs bg-blue-500/10 border border-blue-500/30
                 text-blue-300 hover:bg-blue-500/20 disabled:opacity-50 disabled:cursor-not-allowed transition"
    >
      {loading ? 'Running…' : label}
    </button>
  );
}

function SourceBadge({ source }: { source?: string }) {
  if (!source) return null;
  const isApprox = source.includes('approx') || source.includes('fallback');
  return (
    <span className={`text-[10px] px-1.5 py-0.5 rounded ${
      isApprox
        ? 'bg-amber-500/10 text-amber-500 border border-amber-500/20'
        : 'bg-green-500/10 text-green-400 border border-green-500/20'
    }`}>
      {isApprox ? 'approx' : 'GDS'}
    </span>
  );
}

function ScoreBar({ value, max, color }: { value: number; max: number; color: string }) {
  return (
    <div className="flex items-center gap-2">
      <div className="w-20 h-1.5 bg-slate-700 rounded-full overflow-hidden">
        <div
          className="h-full rounded-full"
          style={{ width: `${Math.min(100, (value / Math.max(max, 0.001)) * 100)}%`, background: color }}
        />
      </div>
      <span className="text-xs font-mono text-slate-300">{value.toFixed(2)}</span>
    </div>
  );
}

function GdsUnavailable() {
  return (
    <div className="py-6 text-center">
      <div className="text-amber-400 text-sm font-medium mb-1">GDS plugin not detected</div>
      <p className="text-slate-500 text-xs max-w-md mx-auto">
        Results shown are Cypher approximations. Install the{' '}
        <span className="text-blue-400 font-mono">neo4j-graph-data-science</span> plugin for
        exact betweenness centrality, Louvain communities, and Jaccard similarity.
      </p>
    </div>
  );
}

// ── 1. Betweenness Centrality ──────────────────────────────────
function BetweennessPanel({ onNavigate }: { onNavigate: (id: string) => void }) {
  const [data, setData]       = useState<BetweennessResult | null>(null);
  const [loading, setLoading] = useState(false);

  const run = useCallback(async () => {
    setLoading(true);
    try { setData(await fetchGdsBetweenness()); }
    catch (e) { console.error(e); }
    finally { setLoading(false); }
  }, []);

  const max = data?.rows[0]?.betweenness_score ?? 1;

  return (
    <GdsSection
      title="Betweenness Centrality"
      subtitle="Who actually connects clusters? Bridge people: brokers, community figures, deal-makers."
    >
      <div className="flex items-center gap-3 mb-4">
        <RunBtn onClick={run} loading={loading} label="Run Betweenness" />
        {data && <SourceBadge source={data.source} />}
      </div>

      {data && (
        <>
          {data.rows[0]?.approximated && <GdsUnavailable />}
          <div className="space-y-1.5">
            {data.rows.map((row, i) => (
              <div
                key={row.id}
                onClick={() => onNavigate(row.id)}
                className="flex items-center gap-3 px-3 py-2 rounded hover:bg-slate-800/60 cursor-pointer group transition"
              >
                <span className="text-slate-600 text-xs font-mono w-5 shrink-0">{i + 1}</span>
                <div
                  className="w-2.5 h-2.5 rounded-full shrink-0"
                  style={{ background: NODE_COLORS[row.type] ?? '#94a3b8' }}
                />
                <div className="flex-1 min-w-0">
                  <span className="text-sm text-white group-hover:text-blue-300 transition truncate block">
                    {row.name}
                  </span>
                  {row.role && <span className="text-xs text-slate-500">{row.role}</span>}
                </div>
                <ScoreBar value={row.betweenness_score} max={max} color="#3B82F6" />
              </div>
            ))}
          </div>
        </>
      )}
    </GdsSection>
  );
}

// ── 2. PageRank ────────────────────────────────────────────────
function PageRankPanel({ onNavigate }: { onNavigate: (id: string) => void }) {
  const [data, setData]       = useState<PageRankResult | null>(null);
  const [loading, setLoading] = useState(false);

  const run = useCallback(async () => {
    setLoading(true);
    try { setData(await fetchGdsPageRank()); }
    catch (e) { console.error(e); }
    finally { setLoading(false); }
  }, []);

  const max = data?.rows[0]?.pagerank_score ?? 1;

  return (
    <GdsSection
      title="PageRank"
      subtitle="Network influence. Not just who has connections — who is connected to important nodes. Ranks owners, connectors, proof nodes."
    >
      <div className="flex items-center gap-3 mb-4">
        <RunBtn onClick={run} loading={loading} label="Run PageRank" />
        {data && <SourceBadge source={data.source} />}
      </div>

      {data && (
        <div className="space-y-1.5">
          {data.rows.map((row, i) => (
            <div
              key={row.id}
              onClick={() => onNavigate(row.id)}
              className="flex items-center gap-3 px-3 py-2 rounded hover:bg-slate-800/60 cursor-pointer group transition"
            >
              <span className="text-slate-600 text-xs font-mono w-5 shrink-0">{i + 1}</span>
              <div
                className="w-2.5 h-2.5 rounded-full shrink-0"
                style={{ background: NODE_COLORS[row.type] ?? '#94a3b8' }}
              />
              <div className="flex-1 min-w-0">
                <span className="text-sm text-white group-hover:text-purple-300 transition truncate block">
                  {row.name}
                </span>
                <span className="text-xs text-slate-500">
                  {row.type}{row.asset_type ? ` · ${row.asset_type}` : ''}
                  {row.opportunity_score != null ? ` · score ${row.opportunity_score.toFixed(0)}` : ''}
                </span>
              </div>
              <ScoreBar value={row.pagerank_score} max={max} color="#A855F7" />
            </div>
          ))}
        </div>
      )}
    </GdsSection>
  );
}

// ── 3. Community Detection ─────────────────────────────────────
function CommunityPanel({ onFocusNodes }: { onFocusNodes: (ids: string[]) => void }) {
  const [data, setData]       = useState<CommunityResult | null>(null);
  const [loading, setLoading] = useState(false);

  const run = useCallback(async () => {
    setLoading(true);
    try { setData(await fetchGdsCommunities()); }
    catch (e) { console.error(e); }
    finally { setLoading(false); }
  }, []);

  return (
    <GdsSection
      title="Louvain Community Detection"
      subtitle="Hidden ecosystems. Automatically surfaces: Lewisville retail cluster · broker-centered networks · Chabad-linked groups."
    >
      <div className="flex items-center gap-3 mb-4">
        <RunBtn onClick={run} loading={loading} label="Detect Communities" />
        {data && <SourceBadge source={data.source} />}
        {data && (
          <span className="text-xs text-slate-500 font-mono">
            {data.communities.length} communities
          </span>
        )}
      </div>

      {data && (
        <>
          {data.communities[0]?.approximated && <GdsUnavailable />}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
            {data.communities.map((c, i) => {
              const colors = ['#3B82F6','#22C55E','#A855F7','#F97316','#14B8A6','#EAB308','#EF4444','#F9A8D4'];
              const color  = colors[i % colors.length];
              return (
                <div
                  key={c.communityId}
                  className="border border-slate-700/50 rounded-lg p-3 hover:border-slate-600 cursor-pointer transition"
                  onClick={() => c.node_ids.length > 0 && onFocusNodes(c.node_ids)}
                >
                  <div className="flex items-center gap-2 mb-2">
                    <span
                      className="w-3 h-3 rounded-full shrink-0"
                      style={{ background: color }}
                    />
                    <span className="text-xs font-semibold text-white">
                      Community {c.communityId}
                    </span>
                    <span className="text-xs text-slate-500">{c.size} members</span>
                    {c.hint_market && (
                      <span className="text-xs text-slate-500 ml-auto">{c.hint_market}</span>
                    )}
                  </div>

                  {/* Type breakdown */}
                  <div className="flex gap-2 mb-2">
                    {[
                      { label: 'P', value: c.person_count,   col: '#3B82F6' },
                      { label: 'Pr', value: c.property_count, col: '#22C55E' },
                      { label: 'M', value: c.market_count,   col: '#F97316' },
                      { label: 'Co', value: c.company_count, col: '#14B8A6' },
                    ].filter(x => x.value > 0).map(x => (
                      <span key={x.label} className="text-[10px] px-1.5 py-0.5 rounded font-mono"
                        style={{ background: x.col + '22', color: x.col }}>
                        {x.label}: {x.value}
                      </span>
                    ))}
                    {c.avg_opp_score > 0 && (
                      <span className="text-[10px] px-1.5 py-0.5 rounded ml-auto"
                        style={{
                          background: c.avg_opp_score >= 70 ? '#EF444422' : '#F9730622',
                          color:      c.avg_opp_score >= 70 ? '#EF4444'   : '#F97316',
                        }}>
                        ⌀{c.avg_opp_score.toFixed(0)}
                      </span>
                    )}
                  </div>

                  {/* Sample names */}
                  <div className="flex flex-wrap gap-1">
                    {c.sample_names.map((n, j) => (
                      <span key={j} className="text-[10px] text-slate-500 truncate max-w-[120px]">
                        {n}
                      </span>
                    ))}
                  </div>

                  {c.hint_asset_type && (
                    <div className="mt-1 text-[10px] text-slate-600">{c.hint_asset_type}</div>
                  )}
                </div>
              );
            })}
          </div>
        </>
      )}
    </GdsSection>
  );
}

// ── 4. Node Similarity ─────────────────────────────────────────
function SimilarityPanel({ onNavigate }: { onNavigate: (id: string) => void }) {
  const [mode, setMode]       = useState<'owners' | 'properties'>('owners');
  const [data, setData]       = useState<SimilarityResult | null>(null);
  const [loading, setLoading] = useState(false);

  const run = useCallback(async () => {
    setLoading(true);
    try { setData(await fetchGdsSimilarity(mode)); }
    catch (e) { console.error(e); }
    finally { setLoading(false); }
  }, [mode]);

  return (
    <GdsSection
      title="Node Similarity (Jaccard)"
      subtitle='"Show me more like this." Finds nodes that share the same portfolio footprint, market exposure, or deal pattern.'
    >
      <div className="flex items-center gap-3 mb-4 flex-wrap">
        <div className="flex rounded overflow-hidden border border-slate-700">
          {(['owners', 'properties'] as const).map(m => (
            <button
              key={m}
              onClick={() => setMode(m)}
              className={`px-3 py-1 text-xs transition ${
                mode === m ? 'bg-slate-700 text-white' : 'text-slate-400 hover:text-white'
              }`}
            >
              {m}
            </button>
          ))}
        </div>
        <RunBtn onClick={run} loading={loading} label="Find Similar" />
        {data && <SourceBadge source={data.source} />}
      </div>

      {data && (
        <div className="space-y-2">
          {data.pairs.map((pair, i) => (
            <div key={i} className="flex items-center gap-2 px-3 py-2 rounded border border-slate-800/60 hover:bg-slate-800/30 transition">
              {/* Node 1 */}
              <button
                onClick={() => onNavigate(pair.id1)}
                className="flex-1 text-left group"
              >
                <div className="text-xs font-medium text-white group-hover:text-blue-300 transition truncate">{pair.name1}</div>
                <div className="text-[10px] text-slate-500">
                  {pair.role1 ?? pair.asset_type1 ?? pair.type1}
                  {pair.score1 != null ? ` · ${pair.score1.toFixed(0)}` : ''}
                </div>
              </button>

              {/* Similarity */}
              <div className="shrink-0 text-center">
                <div
                  className="text-xs font-bold font-mono"
                  style={{
                    color: pair.similarity >= 0.7 ? '#22C55E' :
                           pair.similarity >= 0.4 ? '#F97316' : '#94a3b8',
                  }}
                >
                  {(pair.similarity * 100).toFixed(0)}%
                </div>
                <div className="text-[9px] text-slate-600">similar</div>
              </div>

              {/* Node 2 */}
              <button
                onClick={() => onNavigate(pair.id2)}
                className="flex-1 text-right group"
              >
                <div className="text-xs font-medium text-white group-hover:text-green-300 transition truncate">{pair.name2}</div>
                <div className="text-[10px] text-slate-500">
                  {pair.role2 ?? pair.asset_type2 ?? pair.type2}
                  {pair.score2 != null ? ` · ${pair.score2.toFixed(0)}` : ''}
                </div>
              </button>
            </div>
          ))}

          {data.pairs.length === 0 && (
            <p className="text-sm text-slate-600 text-center py-4">
              No similar pairs found. Add more nodes with shared connections.
            </p>
          )}
        </div>
      )}
    </GdsSection>
  );
}

// ── 5. Weighted Dijkstra Path Finder ──────────────────────────
function PathFinderPanel({ graphNodes, onHighlightPath }: {
  graphNodes: GraphNode[];
  onHighlightPath: (nodeIds: string[]) => void;
}) {
  const [fromQ, setFromQ] = useState('');
  const [toQ,   setToQ]   = useState('');
  const [fromNode, setFromNode] = useState<GraphNode | null>(null);
  const [toNode,   setToNode]   = useState<GraphNode | null>(null);
  const [fromSugg, setFromSugg] = useState<GraphNode[]>([]);
  const [toSugg,   setToSugg]   = useState<GraphNode[]>([]);
  const [result, setResult]     = useState<Awaited<ReturnType<typeof fetchGdsPath>> | null>(null);
  const [loading, setLoading]   = useState(false);
  const [error, setError]       = useState<string | null>(null);

  const suggest = (q: string, setter: (ns: GraphNode[]) => void) => {
    if (!q.trim()) { setter([]); return; }
    setter(graphNodes.filter(n => n.name.toLowerCase().includes(q.toLowerCase())).slice(0, 6));
  };

  const findPath = useCallback(async () => {
    if (!fromNode || !toNode) return;
    setLoading(true);
    setError(null);
    try {
      const r = await fetchGdsPath(fromNode.id, toNode.id);
      setResult(r);
      if (r.found && r.pathNodes) {
        onHighlightPath(r.pathNodes.map(n => String(n.id)));
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [fromNode, toNode, onHighlightPath]);

  const COST_LABELS: Record<string, string> = {
    CONNECTED_TO: '0.5',
    WORKS_FOR:    '0.3',
    OWNS:         '0.4',
    PROOF_NEAR:   '0.5',
    LOCATED_IN:   '0.7',
  };

  return (
    <GdsSection
      title="Weighted Dijkstra — Lowest-Resistance Path"
      subtitle="Not shortest hops. Lowest cost: family=0.1 · trusted client=0.3 · owns=0.4 · proof=0.5 · market=0.7. Find the warmest intro path."
    >
      <div className="grid grid-cols-2 gap-3 mb-4">
        {/* From */}
        <div className="relative">
          <label className="text-[10px] text-slate-500 uppercase tracking-wider block mb-1">From</label>
          <input
            value={fromQ}
            onChange={e => { setFromQ(e.target.value); setFromNode(null); suggest(e.target.value, setFromSugg); }}
            placeholder="Start node…"
            className="w-full px-2.5 py-1.5 rounded bg-slate-800 border border-slate-700 text-xs text-slate-200 placeholder-slate-500 focus:outline-none focus:border-blue-500"
          />
          {fromSugg.length > 0 && (
            <div className="absolute z-10 top-full left-0 right-0 bg-slate-800 border border-slate-700 rounded mt-1 shadow-lg">
              {fromSugg.map(n => (
                <button
                  key={n.id}
                  onClick={() => { setFromNode(n); setFromQ(n.name); setFromSugg([]); }}
                  className="w-full text-left px-3 py-1.5 text-xs text-slate-300 hover:bg-slate-700 flex items-center gap-2"
                >
                  <span className="w-2 h-2 rounded-full shrink-0" style={{ background: NODE_COLORS[n.type] ?? '#94a3b8' }} />
                  {n.name}
                  <span className="text-slate-600 ml-auto">{n.type}</span>
                </button>
              ))}
            </div>
          )}
          {fromNode && <div className="text-[10px] text-green-400 mt-0.5">✓ {fromNode.type}</div>}
        </div>

        {/* To */}
        <div className="relative">
          <label className="text-[10px] text-slate-500 uppercase tracking-wider block mb-1">To</label>
          <input
            value={toQ}
            onChange={e => { setToQ(e.target.value); setToNode(null); suggest(e.target.value, setToSugg); }}
            placeholder="Target owner…"
            className="w-full px-2.5 py-1.5 rounded bg-slate-800 border border-slate-700 text-xs text-slate-200 placeholder-slate-500 focus:outline-none focus:border-blue-500"
          />
          {toSugg.length > 0 && (
            <div className="absolute z-10 top-full left-0 right-0 bg-slate-800 border border-slate-700 rounded mt-1 shadow-lg">
              {toSugg.map(n => (
                <button
                  key={n.id}
                  onClick={() => { setToNode(n); setToQ(n.name); setToSugg([]); }}
                  className="w-full text-left px-3 py-1.5 text-xs text-slate-300 hover:bg-slate-700 flex items-center gap-2"
                >
                  <span className="w-2 h-2 rounded-full shrink-0" style={{ background: NODE_COLORS[n.type] ?? '#94a3b8' }} />
                  {n.name}
                  <span className="text-slate-600 ml-auto">{n.type}</span>
                </button>
              ))}
            </div>
          )}
          {toNode && <div className="text-[10px] text-green-400 mt-0.5">✓ {toNode.type}</div>}
        </div>
      </div>

      <div className="flex items-center gap-3 mb-4">
        <RunBtn
          onClick={findPath}
          loading={loading}
          label="Find Best Path"
        />
        {result?.source && <SourceBadge source={result.source} />}
      </div>

      {error && (
        <div className="text-red-400 text-xs py-2 px-3 rounded bg-red-400/10 border border-red-400/20">
          {error}
        </div>
      )}

      {result && !result.found && (
        <div className="text-slate-500 text-sm text-center py-4">
          No path found between these nodes (within 8 hops).
        </div>
      )}

      {result?.found && result.pathNodes && (
        <div>
          {/* Cost summary */}
          <div className="flex items-center gap-3 mb-4 px-3 py-2 bg-slate-800/50 rounded">
            <div>
              <div className="text-lg font-bold font-mono text-amber-400">
                {(result.totalCost ?? 0).toFixed(2)}
              </div>
              <div className="text-[10px] text-slate-500">total path cost</div>
            </div>
            <div className="ml-4 text-xs text-slate-500">
              {result.pathNodes.length - 1} hops · lower = warmer intro
            </div>
            <div className="ml-auto text-[10px] text-slate-600 border border-slate-700 rounded px-2 py-1">
              <div className="font-semibold text-slate-500 mb-1">cost model</div>
              {Object.entries(COST_LABELS).map(([rel, cost]) => (
                <div key={rel}>{rel} = {cost}</div>
              ))}
            </div>
          </div>

          {/* Path nodes */}
          <div className="flex items-start gap-2 flex-wrap">
            {result.pathNodes.map((n, i) => {
              const relType = result.relTypes?.[i] ?? result.relTypes?.[i - 1];
              const cost    = result.costs?.[i];
              return (
                <div key={n.id} className="flex items-center gap-1.5">
                  {i > 0 && (
                    <div className="text-center shrink-0">
                      <div className="text-[10px] text-slate-500 font-mono">{relType}</div>
                      {cost != null && (
                        <div className="text-[10px] text-amber-500 font-mono">{cost.toFixed(2)}</div>
                      )}
                      <div className="text-slate-600">→</div>
                    </div>
                  )}
                  <div
                    className="flex flex-col items-center gap-1 px-2 py-1.5 rounded border"
                    style={{
                      borderColor: (NODE_COLORS[String(n.type)] ?? '#475569') + '55',
                      background:  (NODE_COLORS[String(n.type)] ?? '#475569') + '11',
                    }}
                  >
                    <div
                      className="w-3 h-3 rounded-full"
                      style={{ background: NODE_COLORS[String(n.type)] ?? '#94a3b8' }}
                    />
                    <div className="text-[10px] text-white font-medium max-w-[80px] text-center truncate">{String(n.name)}</div>
                    <div className="text-[9px] text-slate-500">{String(n.type)}</div>
                  </div>
                </div>
              );
            })}
          </div>

          {/* Alternate paths */}
          {result.alternates && result.alternates.length > 0 && (
            <div className="mt-4 pt-4 border-t border-slate-800">
              <div className="text-xs text-slate-500 mb-2">Alternate paths</div>
              {result.alternates.map((alt, i) => (
                <div key={i} className="text-xs text-slate-600 mb-1">
                  {alt.totalCost.toFixed(2)} cost · {(alt.pathNodes?.length ?? 1) - 1} hops ·{' '}
                  {alt.pathNodes?.map(n => n.name).join(' → ')}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </GdsSection>
  );
}

// ── Write-back banner ──────────────────────────────────────────
function WriteBackBanner({ onWrite }: { onWrite: () => void }) {
  const [result, setResult]   = useState<GdsWriteResult | null>(null);
  const [loading, setLoading] = useState(false);

  const run = useCallback(async () => {
    setLoading(true);
    try { setResult(await writeGdsScores()); }
    catch (e) { console.error(e); }
    finally { setLoading(false); }
    onWrite();
  }, [onWrite]);

  return (
    <div className="flex items-center gap-3 px-4 py-2.5 bg-slate-800/40 border border-slate-700 rounded-lg">
      <div className="flex-1">
        <div className="text-xs font-semibold text-white mb-0.5">Write GDS Scores to Neo4j</div>
        <div className="text-[10px] text-slate-500">
          Persists <span className="text-blue-400 font-mono">connector_score</span> · <span className="text-purple-400 font-mono">gds_pagerank</span> · <span className="text-orange-400 font-mono">community_id</span> as node properties for use in scoring and dossier generation.
        </div>
      </div>
      <button
        onClick={run}
        disabled={loading}
        className="px-3 py-1.5 rounded text-xs bg-green-500/10 border border-green-500/30
                   text-green-300 hover:bg-green-500/20 disabled:opacity-50 transition shrink-0"
      >
        {loading ? 'Writing…' : 'Write Scores'}
      </button>
      {result && (
        <div className="text-xs text-slate-400">
          {result.gds_available ? '✓ GDS write complete' : '✓ Approx scores written'}
        </div>
      )}
    </div>
  );
}

// ── Main GdsPanel export ───────────────────────────────────────
interface Props {
  graphNodes:      GraphNode[];
  onNavigateNode:  (id: string) => void;
  onFocusNodes:    (ids: string[]) => void;
  onHighlightPath: (ids: string[]) => void;
  onWriteComplete: () => void;
}

export default function GdsPanel({
  graphNodes, onNavigateNode, onFocusNodes, onHighlightPath, onWriteComplete,
}: Props) {
  return (
    <div className="flex flex-col gap-4 p-4 overflow-auto h-full">
      {/* Header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-sm font-bold text-white">Graph Data Science</h2>
          <p className="text-xs text-slate-500 mt-0.5">
            From a database of connections → a machine for finding leverage.
            Each algorithm answers a different question about your graph.
          </p>
        </div>
      </div>

      {/* Write-back controls */}
      <WriteBackBanner onWrite={onWriteComplete} />

      {/* Algorithm panels — 2-col grid on large screens */}
      <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
        <BetweennessPanel onNavigate={onNavigateNode} />
        <PageRankPanel    onNavigate={onNavigateNode} />
        <CommunityPanel   onFocusNodes={onFocusNodes} />
        <SimilarityPanel  onNavigate={onNavigateNode} />
      </div>

      {/* Path finder — full width */}
      <PathFinderPanel
        graphNodes={graphNodes}
        onHighlightPath={onHighlightPath}
      />
    </div>
  );
}
