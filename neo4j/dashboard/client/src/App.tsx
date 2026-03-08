import { useState, useEffect, useCallback, useMemo } from 'react';
import type {
  GraphNode, GraphData, NodeType, ViewMode,
  Opportunity, Connector, Cluster, Pipeline, Action, Stats,
  NodeDetail as NodeDetailType,
} from './types';
import { ALL_NODE_TYPES } from './constants';
import {
  fetchGraph, fetchNodeDetail, fetchStats, searchNodes,
  fetchOpportunities, fetchConnectors, fetchClusters, fetchPipeline, fetchActions,
} from './api';

import GraphViewer     from './components/GraphViewer';
import FilterBar       from './components/FilterBar';
import Legend          from './components/Legend';
import NodeDetail      from './components/NodeDetail';
import OpportunityTable from './components/OpportunityTable';
import ConnectorList   from './components/ConnectorList';
import PipelineView    from './components/PipelineView';
import ActionList      from './components/ActionList';
import ClusterGrid     from './components/ClusterGrid';
import GdsPanel        from './components/GdsPanel';

// ── small helpers ─────────────────────────────────────────────
function Panel({
  title, count, children, className = '',
}: {
  title: string; count?: number; children: React.ReactNode; className?: string;
}) {
  return (
    <div className={`bg-slate-900 border border-slate-800 rounded-lg flex flex-col overflow-hidden ${className}`}>
      <div className="px-4 py-2.5 border-b border-slate-800 flex items-center gap-2 shrink-0">
        <h2 className="text-xs font-semibold text-slate-300 uppercase tracking-wider">{title}</h2>
        {count !== undefined && (
          <span className="text-[10px] bg-slate-700 text-slate-400 px-1.5 py-0.5 rounded font-mono">
            {count}
          </span>
        )}
      </div>
      <div className="flex-1 overflow-auto">
        {children}
      </div>
    </div>
  );
}

function Spinner() {
  return (
    <div className="flex items-center justify-center h-full">
      <div className="w-6 h-6 border-2 border-slate-700 border-t-blue-500 rounded-full animate-spin" />
    </div>
  );
}

function ErrorMsg({ msg }: { msg: string }) {
  return (
    <div className="flex items-center justify-center h-full text-red-400 text-sm px-4 text-center">
      {msg}
    </div>
  );
}

// ── main app ──────────────────────────────────────────────────
export default function App() {
  const [view, setView]           = useState<ViewMode>('graph');

  // Graph state
  const [graphData, setGraphData]           = useState<GraphData>({ nodes: [], links: [] });
  const [graphLoading, setGraphLoading]     = useState(true);
  const [graphError, setGraphError]         = useState<string | null>(null);
  const [activeFilters, setActiveFilters]   = useState<Set<NodeType>>(new Set(ALL_NODE_TYPES));
  const [selectedNode, setSelectedNode]     = useState<GraphNode | null>(null);
  const [nodeDetail, setNodeDetail]         = useState<NodeDetailType | null>(null);
  const [detailLoading, setDetailLoading]   = useState(false);
  const [pathMode, setPathMode]             = useState(false);
  const [pathAnchor, setPathAnchor]         = useState<GraphNode | null>(null);
  const [searchQuery, setSearchQuery]       = useState('');

  // Dashboard data
  const [stats, setStats]             = useState<Stats | null>(null);
  const [opportunities, setOpportunities] = useState<Opportunity[]>([]);
  const [connectors, setConnectors]   = useState<Connector[]>([]);
  const [clusters, setClusters]       = useState<Cluster[]>([]);
  const [pipeline, setPipeline]       = useState<Pipeline | null>(null);
  const [actions, setActions]         = useState<Action[]>([]);
  const [dashLoading, setDashLoading] = useState(false);
  const [dashError, setDashError]     = useState<string | null>(null);

  // ── load graph ───────────────────────────────────────────────
  useEffect(() => {
    setGraphLoading(true);
    setGraphError(null);
    Promise.all([fetchGraph(), fetchStats()])
      .then(([g, s]) => { setGraphData(g); setStats(s); })
      .catch(e => setGraphError(e.message))
      .finally(() => setGraphLoading(false));
  }, []);

  // ── load dashboard data when switching views ─────────────────
  useEffect(() => {
    if (view === 'graph') return;
    setDashLoading(true);
    setDashError(null);
    const loaders: Record<ViewMode, () => Promise<void>> = {
      graph:         async () => {},
      opportunities: async () => setOpportunities(await fetchOpportunities()),
      connectors:    async () => setConnectors(await fetchConnectors()),
      pipeline:      async () => { setClusters(await fetchClusters()); setPipeline(await fetchPipeline()); },
      actions:       async () => setActions(await fetchActions()),
    };
    loaders[view]()
      .catch(e => setDashError(e.message))
      .finally(() => setDashLoading(false));
  }, [view]);

  // ── node selection → load detail ─────────────────────────────
  useEffect(() => {
    if (!selectedNode) { setNodeDetail(null); return; }
    setDetailLoading(true);
    fetchNodeDetail(selectedNode.id)
      .then(setNodeDetail)
      .catch(console.error)
      .finally(() => setDetailLoading(false));
  }, [selectedNode]);

  // ── filter helpers ───────────────────────────────────────────
  const toggleFilter = useCallback((t: NodeType) => {
    setActiveFilters(prev => {
      const s = new Set(prev);
      s.has(t) ? s.delete(t) : s.add(t);
      return s;
    });
  }, []);

  const handleSelectAll = useCallback(() => setActiveFilters(new Set(ALL_NODE_TYPES)), []);
  const handleClearAll  = useCallback(() => setActiveFilters(new Set()), []);

  // ── search ───────────────────────────────────────────────────
  const handleSearchSubmit = useCallback(async () => {
    if (!searchQuery.trim()) return;
    try {
      const { nodes } = await searchNodes(searchQuery);
      if (nodes.length > 0) {
        setGraphData(prev => {
          const map = new Map(prev.nodes.map(n => [n.id, n]));
          nodes.forEach(n => map.set(n.id, n));
          return { nodes: [...map.values()], links: prev.links };
        });
        setSelectedNode(nodes[0]);
      }
    } catch (e) { console.error(e); }
  }, [searchQuery]);

  // ── path mode ────────────────────────────────────────────────
  const handlePathSelect = useCallback((a: GraphNode, b: GraphNode) => {
    setPathAnchor(b); // second click becomes new anchor
  }, []);

  const handleTogglePathMode = useCallback(() => {
    setPathMode(p => !p);
    setPathAnchor(null);
  }, []);

  const handleNodeSelect = useCallback((n: GraphNode | null) => {
    if (pathMode && n) {
      setPathAnchor(n);
    } else {
      setSelectedNode(n);
    }
  }, [pathMode]);

  // ── navigate to node from detail panel ──────────────────────
  const handleNavigate = useCallback((n: GraphNode) => {
    setSelectedNode(n);
    setGraphData(prev => {
      if (prev.nodes.find(x => x.id === n.id)) return prev;
      return { nodes: [...prev.nodes, n], links: prev.links };
    });
  }, []);

  // ── nav tabs ─────────────────────────────────────────────────
  const tabs: { key: ViewMode; label: string; accent?: string }[] = [
    { key: 'graph',         label: 'Graph' },
    { key: 'opportunities', label: 'Opportunities' },
    { key: 'connectors',    label: 'Connectors' },
    { key: 'pipeline',      label: 'Pipeline' },
    { key: 'actions',       label: 'Actions' },
    { key: 'gds',           label: 'GDS', accent: '#A855F7' },
  ];

  // ── GDS callbacks ───────────────────────────────────────────
  const handleGdsNavigate = useCallback((id: string) => {
    const node = graphData.nodes.find(n => n.id === id);
    if (node) { setSelectedNode(node); setView('graph'); }
  }, [graphData.nodes]);

  const handleGdsFocusNodes = useCallback((_ids: string[]) => {
    // Switch to graph; the IDs could be used to highlight in future
    setView('graph');
  }, []);

  const handleGdsHighlightPath = useCallback((_ids: string[]) => {
    setView('graph');
  }, []);

  const totalNodes = useMemo(() =>
    stats?.nodes.reduce((a, n) => a + n.count, 0) ?? 0, [stats]);

  return (
    <div className="h-screen flex flex-col overflow-hidden bg-[#0f172a] text-slate-100">

      {/* ── Header ─────────────────────────────────────────── */}
      <header className="flex items-center gap-4 px-4 py-2.5 bg-slate-950 border-b border-slate-800 shrink-0">
        {/* Logo / Title */}
        <div className="flex items-center gap-2">
          <div className="w-6 h-6 rounded bg-blue-500/20 border border-blue-500/40 flex items-center justify-center text-blue-400 text-xs font-bold">
            G
          </div>
          <span className="text-sm font-semibold text-white tracking-tight">
            Opportunity Intelligence
          </span>
          <span className="hidden sm:block text-xs text-slate-600">Graph</span>
        </div>

        {/* Nav */}
        <nav className="flex items-center gap-0.5 ml-4">
          {tabs.map(t => (
            <button
              key={t.key}
              onClick={() => setView(t.key)}
              className={`px-3 py-1.5 rounded text-xs font-medium transition ${
                view === t.key
                  ? 'bg-slate-700 text-white'
                  : 'text-slate-400 hover:text-white hover:bg-slate-800'
              }`}
              style={t.accent && view === t.key
                ? { color: t.accent, background: t.accent + '22' }
                : t.accent
                ? { color: t.accent + 'bb' }
                : undefined}
            >
              {t.label}
            </button>
          ))}
        </nav>

        {/* Stats chips */}
        <div className="ml-auto hidden md:flex items-center gap-3 text-xs text-slate-500 font-mono">
          {stats?.nodes.slice(0, 5).map(n => (
            <span key={n.label}>
              {n.label} <span className="text-slate-400">{n.count}</span>
            </span>
          ))}
          {totalNodes > 0 && (
            <span className="text-slate-600 border-l border-slate-800 pl-3">
              {totalNodes} total
            </span>
          )}
        </div>
      </header>

      {/* ── Graph View ────────────────────────────────────── */}
      {view === 'graph' && (
        <>
          <FilterBar
            activeFilters={activeFilters}
            onToggle={toggleFilter}
            onClearAll={handleClearAll}
            onSelectAll={handleSelectAll}
            stats={stats}
            searchQuery={searchQuery}
            onSearchChange={setSearchQuery}
            onSearchSubmit={handleSearchSubmit}
            pathMode={pathMode}
            onTogglePathMode={handleTogglePathMode}
          />

          <div className="flex flex-1 overflow-hidden">
            {/* Graph canvas */}
            <div className="flex-1 relative overflow-hidden">
              {graphLoading && <Spinner />}
              {graphError && <ErrorMsg msg={graphError} />}
              {!graphLoading && !graphError && (
                <GraphViewer
                  data={graphData}
                  activeFilters={activeFilters}
                  selectedNode={selectedNode}
                  onNodeSelect={handleNodeSelect}
                  pathMode={pathMode}
                  pathAnchor={pathAnchor}
                  onPathSelect={handlePathSelect}
                />
              )}
            </div>

            {/* Node detail panel */}
            {(selectedNode || detailLoading) && !pathMode && (
              <div className="w-72 xl:w-80 shrink-0 overflow-hidden">
                {detailLoading ? (
                  <div className="h-full bg-slate-900 border-l border-slate-800 flex items-center justify-center">
                    <div className="w-5 h-5 border-2 border-slate-700 border-t-blue-500 rounded-full animate-spin" />
                  </div>
                ) : nodeDetail ? (
                  <NodeDetail
                    node={nodeDetail.node}
                    connections={nodeDetail.connections}
                    onClose={() => { setSelectedNode(null); setNodeDetail(null); }}
                    onNavigate={handleNavigate}
                    onStartPath={n => { setPathMode(true); setPathAnchor(n); }}
                  />
                ) : null}
              </div>
            )}
          </div>

          <Legend />
        </>
      )}

      {/* ── Opportunities View ────────────────────────────── */}
      {view === 'opportunities' && (
        <div className="flex-1 overflow-auto p-4">
          <Panel title="Top Opportunities" count={opportunities.length} className="h-full">
            {dashLoading ? <Spinner /> :
             dashError   ? <ErrorMsg msg={dashError} /> :
             <OpportunityTable
               rows={opportunities}
               onRowClick={id => {
                 const node = graphData.nodes.find(n => n.property_id === id);
                 if (node) { setView('graph'); setSelectedNode(node); }
               }}
             />}
          </Panel>
        </div>
      )}

      {/* ── Connectors View ───────────────────────────────── */}
      {view === 'connectors' && (
        <div className="flex-1 overflow-auto p-4">
          <Panel title="Top Connectors" count={connectors.length} className="h-full">
            {dashLoading ? <Spinner /> :
             dashError   ? <ErrorMsg msg={dashError} /> :
             <ConnectorList rows={connectors} />}
          </Panel>
        </div>
      )}

      {/* ── Pipeline View ─────────────────────────────────── */}
      {view === 'pipeline' && (
        <div className="flex-1 overflow-auto p-4 grid grid-cols-1 xl:grid-cols-2 gap-4">
          <Panel title="Opportunity Pipeline" className="min-h-64">
            {dashLoading ? <Spinner /> :
             dashError   ? <ErrorMsg msg={dashError} /> :
             pipeline    ? <PipelineView data={pipeline} /> : null}
          </Panel>
          <Panel title="Active Clusters" count={clusters.length} className="min-h-64">
            {dashLoading ? <Spinner /> :
             dashError   ? <ErrorMsg msg={dashError} /> :
             <ClusterGrid rows={clusters} />}
          </Panel>
        </div>
      )}

      {/* ── Actions View ──────────────────────────────────── */}
      {view === 'actions' && (
        <div className="flex-1 overflow-auto p-4">
          <Panel title="Best Next Actions" count={actions.length} className="h-full">
            {dashLoading ? <Spinner /> :
             dashError   ? <ErrorMsg msg={dashError} /> :
             <ActionList rows={actions} />}
          </Panel>
        </div>
      )}

      {/* ── GDS View ──────────────────────────────────────── */}
      {view === 'gds' && (
        <div className="flex-1 overflow-hidden">
          <GdsPanel
            graphNodes={graphData.nodes}
            onNavigateNode={handleGdsNavigate}
            onFocusNodes={handleGdsFocusNodes}
            onHighlightPath={handleGdsHighlightPath}
            onWriteComplete={() => {
              // Refresh stats after write-back so new scores appear in graph
              fetchStats().then(setStats).catch(console.error);
            }}
          />
        </div>
      )}
    </div>
  );
}
