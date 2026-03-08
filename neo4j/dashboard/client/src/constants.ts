import type { NodeType } from './types';

// ── Node colors (matching user spec) ─────────────────────────
// Person = blue  |  Property = green  |  Market = orange
// ProofProject = purple  |  StormEvent = red
// Company = teal  |  User = yellow

export const NODE_COLORS: Record<NodeType | string, string> = {
  Person:       '#3B82F6',  // blue-500
  Property:     '#22C55E',  // green-500
  Market:       '#F97316',  // orange-500
  ProofProject: '#A855F7',  // purple-500
  StormEvent:   '#EF4444',  // red-500
  Company:      '#14B8A6',  // teal-500
  User:         '#EAB308',  // yellow-500
};

export const NODE_BORDER_COLORS: Record<NodeType | string, string> = {
  Person:       '#93C5FD',
  Property:     '#86EFAC',
  Market:       '#FED7AA',
  ProofProject: '#D8B4FE',
  StormEvent:   '#FCA5A5',
  Company:      '#99F6E4',
  User:         '#FDE68A',
};

export const NODE_RADIUS: Record<NodeType | string, number> = {
  Property:     9,
  Person:       8,
  Company:      8,
  Market:       10,
  StormEvent:   9,
  ProofProject: 7,
  User:         6,
};

export const LINK_COLORS: Record<string, string> = {
  OWNS:          '#6EE7B7',  // green
  CONNECTED_TO:  '#93C5FD',  // blue
  LOCATED_IN:    '#FCD34D',  // yellow
  AFFECTED_BY:   '#FCA5A5',  // red
  PROOF_NEAR:    '#C4B5FD',  // purple
  WORKS_FOR:     '#67E8F9',  // cyan
  MANAGES:       '#A5B4FC',  // indigo
  SIMILAR_TO:    '#D1D5DB',  // gray
  REFERENCES:    '#F9A8D4',  // pink
  COMPLETED_BY:  '#86EFAC',  // green
  default:       '#475569',
};

export const ALL_NODE_TYPES: NodeType[] = [
  'Person', 'Property', 'Market', 'ProofProject', 'StormEvent', 'Company', 'User',
];

export const TIER_COLORS: Record<string, string> = {
  HOT:    '#EF4444',
  WARM:   '#F97316',
  ACTIVE: '#EAB308',
  WATCH:  '#3B82F6',
  COLD:   '#475569',
};

export const URGENCY_COLORS: Record<string, string> = {
  HIGH:   '#EF4444',
  MEDIUM: '#F97316',
  LOW:    '#3B82F6',
};
