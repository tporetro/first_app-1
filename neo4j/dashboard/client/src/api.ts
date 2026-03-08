import type {
  GraphData, NodeDetail, Stats,
  Opportunity, Connector, Cluster, Pipeline, Action,
  BetweennessResult, PageRankResult, CommunityResult,
  SimilarityResult, PathResult, GdsWriteResult,
} from './types';

const BASE = '/api';

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`);
  if (!res.ok) {
    const { error } = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(error ?? res.statusText);
  }
  return res.json() as Promise<T>;
}

// Graph endpoints
export const fetchGraph = (labels?: string[], limit = 300) => {
  const params = new URLSearchParams();
  if (labels?.length) params.set('labels', labels.join(','));
  params.set('limit', String(limit));
  return get<GraphData>(`/graph?${params}`);
};

export const fetchNodeDetail = (id: string) =>
  get<NodeDetail>(`/graph/node/${id}`);

export const fetchPath = (from: string, to: string) =>
  get<{ found: boolean; nodes: GraphData['nodes']; links: GraphData['links'] }>(
    `/graph/path?from=${from}&to=${to}`
  );

export const searchNodes = (q: string) =>
  get<{ nodes: GraphData['nodes'] }>(`/graph/search?q=${encodeURIComponent(q)}`);

// Dashboard endpoints
export const fetchStats         = () => get<Stats>('/stats');
export const fetchOpportunities = () => get<Opportunity[]>('/opportunities');
export const fetchConnectors    = () => get<Connector[]>('/connectors');
export const fetchClusters      = () => get<Cluster[]>('/clusters');
export const fetchPipeline      = () => get<Pipeline>('/pipeline');
export const fetchActions       = () => get<Action[]>('/actions');

// ── GDS endpoints ─────────────────────────────────────────────
// Each falls back gracefully when GDS plugin is not installed.

export const fetchGdsBetweenness = () =>
  get<BetweennessResult>('/gds/betweenness');

export const fetchGdsPageRank    = () =>
  get<PageRankResult>('/gds/pagerank');

export const fetchGdsCommunities = () =>
  get<CommunityResult>('/gds/communities');

export const fetchGdsSimilarity  = (mode: 'owners' | 'properties') =>
  get<SimilarityResult>(`/gds/similarity?mode=${mode}`);

export const fetchGdsPath = (from: string, to: string) =>
  get<PathResult>(`/gds/paths?from=${from}&to=${to}`);

export const writeGdsScores = (): Promise<GdsWriteResult> =>
  fetch('/api/gds/write', { method: 'POST' }).then(r => r.json());
