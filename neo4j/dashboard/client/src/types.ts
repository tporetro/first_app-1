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

// ── View modes ───────────────────────────────────────────────

export type ViewMode = 'graph' | 'opportunities' | 'connectors' | 'pipeline' | 'actions';
