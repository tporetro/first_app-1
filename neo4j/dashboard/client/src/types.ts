// ── Graph node / link types ──────────────────────────────────

export type NodeType =
  | 'Person'
  | 'Property'
  | 'Market'
  | 'ProofProject'
  | 'StormEvent'
  | 'Company'
  | 'User';

export interface GraphNode {
  id:     string;
  type:   NodeType;
  labels: string[];
  name:   string;
  // force-graph simulation injects these at runtime
  x?: number;
  y?: number;
  vx?: number;
  vy?: number;
  fx?: number | null;
  fy?: number | null;
  [key: string]: unknown;
}

export interface GraphLink {
  id:     string;
  source: string | GraphNode;
  target: string | GraphNode;
  type:   string;
  [key: string]: unknown;
}

export interface GraphData {
  nodes: GraphNode[];
  links: GraphLink[];
}

// ── Node neighborhood ─────────────────────────────────────────

export interface Connection {
  direction: 'in' | 'out';
  relType:   string;
  relId:     string | number;
  relProps:  Record<string, unknown>;
  neighbor:  GraphNode;
}

export interface NodeDetail {
  node:        GraphNode;
  connections: Connection[];
  subgraph:    GraphData;
}

// ── Dashboard data types ──────────────────────────────────────

export interface Opportunity {
  id:               string;
  property:         string;
  address:          string;
  city:             string;
  state:            string;
  market:           string;
  asset_type:       string;
  building_sqft:    number;
  roof_age:         number;
  roof_condition:   string;
  opportunity_score: number;
  estimated_value:  number;
  owner:            string;
  owner_email:      string;
  score_storm:      number;
  score_damage:     number;
  score_value:      number;
  score_proof:      number;
  score_network:    number;
  score_engagement: number;
}

export interface Connector {
  id:                    string;
  name:                  string;
  role:                  string;
  email:                 string;
  trust_score:           number;
  influence_score:       number;
  connection_count:      number;
  owners_reachable:      number;
  reachable_properties:  number;
  pipeline_value:        number;
  avg_opportunity_score: number;
}

export interface Cluster {
  market_id:             string;
  market:                string;
  state:                 string;
  market_storm_risk:     number;
  asset_type:            string;
  property_count:        number;
  avg_opportunity_score: number;
  total_value:           number;
  storm_event_count:     number;
  sample_properties:     string[];
}

export interface PipelineTier {
  tier:           string;
  property_count: number;
  total_value:    number;
  avg_score:      number;
  max_score:      number;
}

export interface PipelineFunnel {
  teaser_views:          number;
  reports_generated:     number;
  inspections_requested: number;
  activation_rate:       number;
}

export interface Pipeline {
  tiers:  PipelineTier[];
  funnel: PipelineFunnel;
}

export interface Action {
  action:           string;
  target_node:      string;
  property_id:      string;
  opportunity_score: number;
  estimated_value:  number;
  owner_name:       string;
  owner_email:      string;
  reason:           string;
  urgency:          'HIGH' | 'MEDIUM' | 'LOW';
}

export interface Stats {
  nodes:         { label: string; count: number }[];
  relationships: { type: string;  count: number }[];
}

// ── GDS result types ─────────────────────────────────────────

/** Shared envelope for GDS endpoints */
export interface GdsResponse<T> {
  algorithm: string;
  source:    string;       // 'gds' | 'cypher_degree_approx' | etc.
  gds?:      boolean;      // false when GDS plugin not available
  reason?:   string;
}

// 1. Betweenness Centrality
export interface BetweennessRow {
  id:               string;
  name:             string;
  type:             string;
  role:             string | null;
  email:            string | null;
  trust_score:      number | null;
  influence_score:  number | null;
  betweenness_score: number;
  approximated:     boolean;
}
export interface BetweennessResult extends GdsResponse<BetweennessRow> {
  rows: BetweennessRow[];
}

// 2. PageRank
export interface PageRankRow {
  id:               string;
  name:             string;
  type:             string;
  role:             string | null;
  asset_type:       string | null;
  opportunity_score: number | null;
  pagerank_score:   number;
  approximated:     boolean;
}
export interface PageRankResult extends GdsResponse<PageRankRow> {
  rows: PageRankRow[];
}

// 3. Community Detection
export interface CommunityRow {
  communityId:     number;
  size:            number;
  sample_names:    string[];
  node_ids:        string[];
  person_count:    number;
  property_count:  number;
  market_count:    number;
  company_count:   number;
  hint_asset_type: string | null;
  hint_market:     string | null;
  avg_opp_score:   number;
  approximated:    boolean;
}
export interface CommunityResult extends GdsResponse<CommunityRow> {
  communities: CommunityRow[];
}

// 4. Node Similarity
export interface SimilarityPair {
  id1:         string;
  name1:       string;
  type1:       string;
  role1:       string | null;
  asset_type1: string | null;
  score1:      number | null;
  id2:         string;
  name2:       string;
  type2:       string;
  role2:       string | null;
  asset_type2: string | null;
  score2:      number | null;
  similarity:  number;
}
export interface SimilarityResult extends GdsResponse<SimilarityPair> {
  mode:  string;
  pairs: SimilarityPair[];
}

// 5. Weighted Dijkstra
export interface PathResult {
  found:      boolean;
  source?:    string;
  totalCost?: number;
  pathNodes?: {
    id: string; name: string; type: string;
    [k: string]: unknown;
  }[];
  costs?:     number[];
  relTypes?:  string[];
  alternates?: {
    totalCost: number;
    pathNodes: PathResult['pathNodes'];
    relTypes: string[];
  }[];
}

// GDS write-back
export interface GdsWriteResult {
  ok:            boolean;
  gds_available: boolean;
  written: Record<string, { property: string; nodesWritten?: number; communities?: number; ms?: number; source?: string }>;
  errors:  Record<string, string>;
}

// ── View modes ───────────────────────────────────────────────

export type ViewMode = 'graph' | 'opportunities' | 'connectors' | 'pipeline' | 'actions' | 'gds';
