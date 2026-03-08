import type {
  GraphData, NodeDetail, Stats,
  Opportunity, Connector, Cluster, Pipeline, Action,
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
export const fetchStats        = () => get<Stats>('/stats');
export const fetchOpportunities = () => get<Opportunity[]>('/opportunities');
export const fetchConnectors    = () => get<Connector[]>('/connectors');
export const fetchClusters      = () => get<Cluster[]>('/clusters');
export const fetchPipeline      = () => get<Pipeline>('/pipeline');
export const fetchActions       = () => get<Action[]>('/actions');
