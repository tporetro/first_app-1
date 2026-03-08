import {
  useRef, useCallback, useEffect, useState, useMemo,
} from 'react';
import ForceGraph2D from 'react-force-graph-2d';
import type { GraphNode, GraphLink, GraphData, NodeType } from '../types';
import { NODE_COLORS, NODE_RADIUS, LINK_COLORS } from '../constants';
import { fetchNodeDetail, fetchPath } from '../api';

interface Props {
  data:             GraphData;
  activeFilters:    Set<NodeType>;
  selectedNode:     GraphNode | null;
  onNodeSelect:     (node: GraphNode | null) => void;
  pathMode:         boolean;
  pathAnchor:       GraphNode | null;
  onPathSelect:     (a: GraphNode, b: GraphNode) => void;
}

// ── helpers ──────────────────────────────────────────────────
const nodeId = (n: GraphNode | string) =>
  typeof n === 'string' ? n : n.id;

function truncate(s: string, max: number) {
  return s.length > max ? s.slice(0, max - 1) + '…' : s;
}

// ── component ─────────────────────────────────────────────────
export default function GraphViewer({
  data,
  activeFilters,
  selectedNode,
  onNodeSelect,
  pathMode,
  pathAnchor,
  onPathSelect,
}: Props) {
  const fgRef       = useRef<any>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const [dims, setDims]         = useState({ w: 800, h: 600 });
  const [tooltip, setTooltip]   = useState<{ x: number; y: number; text: string } | null>(null);
  const [highlightNodes, setHighlightNodes] = useState<Set<string>>(new Set());
  const [highlightLinks, setHighlightLinks] = useState<Set<string>>(new Set());
  const [expandedNodes, setExpandedNodes]   = useState<Set<string>>(new Set());
  const [overlayData, setOverlayData]       = useState<GraphData | null>(null);
  const [pathNodes, setPathNodes]           = useState<Set<string>>(new Set());
  const [pathLinks, setPathLinks]           = useState<Set<string>>(new Set());

  // ── resize observer ────────────────────────────────────────
  useEffect(() => {
    if (!containerRef.current) return;
    const obs = new ResizeObserver(entries => {
      const { width, height } = entries[0].contentRect;
      setDims({ w: width, h: height });
    });
    obs.observe(containerRef.current);
    return () => obs.disconnect();
  }, []);

  // ── merge overlay into base data ───────────────────────────
  const mergedData = useMemo<GraphData>(() => {
    if (!overlayData) return data;
    const nodeMap = new Map(data.nodes.map(n => [n.id, n]));
    for (const n of overlayData.nodes) if (!nodeMap.has(n.id)) nodeMap.set(n.id, n);
    const linkSet = new Set(data.links.map((l: GraphLink) => `${nodeId(l.source as GraphNode)}-${nodeId(l.target as GraphNode)}-${l.type}`));
    const extraLinks = overlayData.links.filter((l: GraphLink) => {
      const key = `${nodeId(l.source as GraphNode)}-${nodeId(l.target as GraphNode)}-${l.type}`;
      return !linkSet.has(key);
    });
    return { nodes: [...nodeMap.values()], links: [...data.links, ...extraLinks] };
  }, [data, overlayData]);

  // ── filtered data ──────────────────────────────────────────
  const filteredData = useMemo<GraphData>(() => {
    if (activeFilters.size === 0) return mergedData;
    const allowed = new Set(mergedData.nodes.filter(n => activeFilters.has(n.type as NodeType)).map(n => n.id));
    return {
      nodes: mergedData.nodes.filter(n => activeFilters.has(n.type as NodeType)),
      links: mergedData.links.filter((l: GraphLink) =>
        allowed.has(nodeId(l.source as GraphNode)) &&
        allowed.has(nodeId(l.target as GraphNode))
      ),
    };
  }, [mergedData, activeFilters]);

  // ── customise d3 forces once graph mounts ─────────────────
  useEffect(() => {
    if (!fgRef.current) return;
    fgRef.current.d3Force('charge')?.strength(-200);
    fgRef.current.d3Force('link')?.distance(80);
    fgRef.current.d3Force('collide', null);
  }, []);

  // ── center on selected node ────────────────────────────────
  useEffect(() => {
    if (!selectedNode || !fgRef.current) return;
    const n = filteredData.nodes.find(nd => nd.id === selectedNode.id);
    if (n?.x != null && n.y != null) {
      fgRef.current.centerAt(n.x, n.y, 500);
      fgRef.current.zoom(2.5, 500);
    }
  }, [selectedNode]);

  // ── expand node on double-click ────────────────────────────
  const handleDblClick = useCallback(async (node: object) => {
    const n = node as GraphNode;
    if (expandedNodes.has(n.id)) return;
    try {
      const detail = await fetchNodeDetail(n.id);
      setOverlayData(prev => {
        if (!prev) return detail.subgraph;
        const nodeMap = new Map(prev.nodes.map(x => [x.id, x]));
        for (const nd of detail.subgraph.nodes) nodeMap.set(nd.id, nd);
        return { nodes: [...nodeMap.values()], links: [...prev.links, ...detail.subgraph.links] };
      });
      setExpandedNodes(p => new Set(p).add(n.id));
      // Highlight newly added neighbors
      const nbrIds = new Set(detail.subgraph.nodes.map((x: GraphNode) => x.id));
      setHighlightNodes(nbrIds);
      setTimeout(() => setHighlightNodes(new Set()), 2000);
    } catch (e) {
      console.error('expand failed', e);
    }
  }, [expandedNodes]);

  // ── path routing ───────────────────────────────────────────
  const handleNodeClick = useCallback(async (node: object) => {
    const n = node as GraphNode;
    if (pathMode && pathAnchor && pathAnchor.id !== n.id) {
      onPathSelect(pathAnchor, n);
      // Fetch shortest path
      try {
        const result = await fetchPath(pathAnchor.id, n.id);
        if (result.found) {
          const pNodes = new Set(result.nodes.map((x: GraphNode) => x.id));
          const pLinks = new Set(result.links.map((l: GraphLink) => l.id));
          setPathNodes(pNodes);
          setPathLinks(pLinks);
          setOverlayData(prev => {
            const nodeMap = new Map((prev?.nodes ?? []).map(x => [x.id, x]));
            for (const nd of result.nodes) nodeMap.set(nd.id, nd);
            return { nodes: [...nodeMap.values()], links: [...(prev?.links ?? []), ...result.links] };
          });
        }
      } catch (e) {
        console.error('path failed', e);
      }
    } else {
      setPathNodes(new Set());
      setPathLinks(new Set());
      onNodeSelect(n);
    }
  }, [pathMode, pathAnchor, onPathSelect, onNodeSelect]);

  // ── node highlight on hover ────────────────────────────────
  const handleNodeHover = useCallback((node: object | null, event?: MouseEvent) => {
    if (!node) {
      setHighlightNodes(new Set());
      setHighlightLinks(new Set());
      setTooltip(null);
      return;
    }
    const n = node as GraphNode;
    // Collect connected node ids
    const connectedIds = new Set<string>([n.id]);
    const connectedLinks = new Set<string>();
    for (const l of filteredData.links as GraphLink[]) {
      const src = nodeId(l.source as GraphNode);
      const tgt = nodeId(l.target as GraphNode);
      if (src === n.id || tgt === n.id) {
        connectedIds.add(src);
        connectedIds.add(tgt);
        connectedLinks.add(l.id);
      }
    }
    setHighlightNodes(connectedIds);
    setHighlightLinks(connectedLinks);

    if (event) {
      setTooltip({ x: event.clientX + 12, y: event.clientY - 10, text: n.name });
    }
  }, [filteredData.links]);

  const handleLinkHover = useCallback((link: object | null, event?: MouseEvent) => {
    if (!link) { setTooltip(null); return; }
    const l = link as GraphLink;
    if (event) {
      setTooltip({ x: event.clientX + 12, y: event.clientY - 10, text: l.type });
    }
  }, []);

  // ── custom node renderer ───────────────────────────────────
  const drawNode = useCallback((node: object, ctx: CanvasRenderingContext2D, globalScale: number) => {
    const n   = node as GraphNode;
    const x   = n.x ?? 0;
    const y   = n.y ?? 0;
    const r   = NODE_RADIUS[n.type] ?? 7;
    const col = NODE_COLORS[n.type] ?? '#94a3b8';

    const isSelected    = selectedNode?.id === n.id;
    const isHighlighted = highlightNodes.size === 0 || highlightNodes.has(n.id);
    const isPath        = pathNodes.size > 0 && pathNodes.has(n.id);
    const alpha         = isHighlighted ? 1 : 0.25;

    ctx.globalAlpha = alpha;

    // Glow for selected / path
    if (isSelected || isPath) {
      ctx.beginPath();
      ctx.arc(x, y, r + 5, 0, 2 * Math.PI);
      const grd = ctx.createRadialGradient(x, y, r, x, y, r + 5);
      grd.addColorStop(0, col + 'aa');
      grd.addColorStop(1, col + '00');
      ctx.fillStyle = grd;
      ctx.fill();
    }

    // Node circle
    ctx.beginPath();
    ctx.arc(x, y, r, 0, 2 * Math.PI);
    ctx.fillStyle = col;
    ctx.fill();

    // Border
    ctx.strokeStyle = isSelected ? '#ffffff' : isPath ? '#f59e0b' : col + 'cc';
    ctx.lineWidth   = isSelected ? 2.5 / globalScale : 1 / globalScale;
    ctx.stroke();

    // Label (visible from zoom ~0.6+)
    if (globalScale > 0.6) {
      const fontSize = Math.max(7, 10 / globalScale);
      const label    = truncate(n.name, 18);
      ctx.font            = `${fontSize}px Inter, sans-serif`;
      ctx.textAlign       = 'center';
      ctx.textBaseline    = 'top';
      ctx.fillStyle       = 'rgba(226,232,240,0.9)';
      ctx.fillText(label, x, y + r + 2 / globalScale);
    }

    ctx.globalAlpha = 1;
  }, [selectedNode, highlightNodes, pathNodes]);

  // ── link color ─────────────────────────────────────────────
  const linkColor = useCallback((link: object) => {
    const l  = link as GraphLink;
    const id = l.id;
    if (pathLinks.size > 0 && pathLinks.has(id)) return '#f59e0b';
    const col = LINK_COLORS[l.type] ?? LINK_COLORS.default;
    if (highlightLinks.size === 0) return col + '66';
    return highlightLinks.has(id) ? col + 'cc' : col + '1a';
  }, [highlightLinks, pathLinks]);

  const linkWidth = useCallback((link: object) => {
    const l = link as GraphLink;
    if (pathLinks.has(l.id)) return 2.5;
    return highlightLinks.has(l.id) ? 1.5 : 0.8;
  }, [highlightLinks, pathLinks]);

  const linkParticles = useCallback((link: object) => {
    const l = link as GraphLink;
    return pathLinks.has(l.id) ? 4 : 0;
  }, [pathLinks]);

  // ── controls ───────────────────────────────────────────────
  const zoomIn  = () => fgRef.current?.zoom(fgRef.current.zoom() * 1.3, 300);
  const zoomOut = () => fgRef.current?.zoom(fgRef.current.zoom() / 1.3, 300);
  const fitAll  = () => fgRef.current?.zoomToFit(400, 40);
  const clearOverlay = () => {
    setOverlayData(null);
    setExpandedNodes(new Set());
    setPathNodes(new Set());
    setPathLinks(new Set());
  };

  return (
    <div ref={containerRef} className="relative w-full h-full bg-[#0a1628] rounded-lg overflow-hidden">

      {/* Graph canvas */}
      <ForceGraph2D
        ref={fgRef}
        graphData={filteredData}
        width={dims.w}
        height={dims.h}
        backgroundColor="#0a1628"
        nodeCanvasObject={drawNode}
        nodeCanvasObjectMode={() => 'replace'}
        linkColor={linkColor}
        linkWidth={linkWidth}
        linkDirectionalArrowLength={4}
        linkDirectionalArrowRelPos={1}
        linkDirectionalArrowColor={linkColor}
        linkDirectionalParticles={linkParticles}
        linkDirectionalParticleColor={() => '#f59e0b'}
        linkDirectionalParticleWidth={2}
        onNodeClick={handleNodeClick}
        onNodeRightClick={handleDblClick}
        onNodeHover={(n, _p, e) => handleNodeHover(n, e as MouseEvent)}
        onLinkHover={(l, _p, e) => handleLinkHover(l, e as MouseEvent)}
        enableNodeDrag
        enableZoomInteraction
        cooldownTicks={120}
      />

      {/* Zoom controls */}
      <div className="absolute top-3 right-3 flex flex-col gap-1">
        {[
          { label: '+', fn: zoomIn,   title: 'Zoom in'  },
          { label: '−', fn: zoomOut,  title: 'Zoom out' },
          { label: '⊡', fn: fitAll,   title: 'Fit all'  },
        ].map(b => (
          <button
            key={b.label}
            onClick={b.fn}
            title={b.title}
            className="w-8 h-8 rounded bg-slate-800/90 border border-slate-700 text-slate-300
                       hover:bg-slate-700 hover:text-white transition text-sm font-mono"
          >
            {b.label}
          </button>
        ))}
        {(overlayData || pathNodes.size > 0) && (
          <button
            onClick={clearOverlay}
            title="Clear expansions and paths"
            className="w-8 h-8 rounded bg-red-900/60 border border-red-700 text-red-300
                       hover:bg-red-800 hover:text-white transition text-xs font-mono"
          >
            ✕
          </button>
        )}
      </div>

      {/* Counts */}
      <div className="absolute bottom-3 left-3 text-xs text-slate-500 font-mono">
        {filteredData.nodes.length} nodes · {filteredData.links.length} links
        {pathNodes.size > 0 && (
          <span className="ml-2 text-amber-400">path: {pathNodes.size} nodes</span>
        )}
      </div>

      {/* Hint */}
      <div className="absolute bottom-3 right-3 text-xs text-slate-600">
        click = select · right-click = expand · drag = reposition
      </div>

      {/* Hover tooltip */}
      {tooltip && (
        <div
          className="graph-tooltip"
          style={{ left: tooltip.x, top: tooltip.y }}
        >
          {tooltip.text}
        </div>
      )}

      {/* Path mode indicator */}
      {pathMode && (
        <div className="absolute top-3 left-3 flex items-center gap-2 bg-amber-500/20 border border-amber-500/50
                        rounded px-3 py-1.5 text-amber-300 text-xs">
          <span className="w-2 h-2 rounded-full bg-amber-400 animate-pulse" />
          Path mode — {pathAnchor ? `from "${pathAnchor.name}" — click target` : 'click start node'}
        </div>
      )}
    </div>
  );
}
