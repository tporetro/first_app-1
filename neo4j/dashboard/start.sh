#!/usr/bin/env bash
# ============================================================
# Opportunity Intelligence Dashboard — Start Script
# Starts both the Express API server and the Vite dev client.
#
# Usage:
#   chmod +x start.sh
#   NEO4J_PASSWORD=yourpassword ./start.sh
#
# Then open: http://localhost:3000
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SCRIPT_DIR}/server"
CLIENT_DIR="${SCRIPT_DIR}/client"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Export Neo4j env vars for the server process
export NEO4J_URI="${NEO4J_URI:-bolt://localhost:7687}"
export NEO4J_USER="${NEO4J_USER:-neo4j}"
export NEO4J_PASSWORD="${NEO4J_PASSWORD:-neo4j}"
export NEO4J_DB="${NEO4J_DB:-neo4j}"
export PORT="${PORT:-3001}"

echo ""
echo "============================================================"
echo " Opportunity Intelligence Dashboard"
echo "============================================================"
echo " Neo4j  : ${NEO4J_URI}"
echo " API    : http://localhost:${PORT}"
echo " App    : http://localhost:3000"
echo "============================================================"
echo ""

# Install server deps if needed
if [ ! -d "${SERVER_DIR}/node_modules" ]; then
  echo -e "${CYAN}[server]${NC} Installing dependencies…"
  (cd "${SERVER_DIR}" && npm install)
fi

# Install client deps if needed
if [ ! -d "${CLIENT_DIR}/node_modules" ]; then
  echo -e "${CYAN}[client]${NC} Installing dependencies…"
  (cd "${CLIENT_DIR}" && npm install)
fi

# Copy .env if not present
if [ ! -f "${SERVER_DIR}/.env" ] && [ -f "${SERVER_DIR}/.env.example" ]; then
  cp "${SERVER_DIR}/.env.example" "${SERVER_DIR}/.env"
  sed -i "s|NEO4J_PASSWORD=neo4j|NEO4J_PASSWORD=${NEO4J_PASSWORD}|" "${SERVER_DIR}/.env"
  echo -e "${GREEN}[server]${NC} Created .env from template"
fi

# Start server in background
echo -e "${GREEN}[server]${NC} Starting API on :${PORT}…"
(cd "${SERVER_DIR}" && node index.js) &
SERVER_PID=$!

# Give server a moment to start
sleep 1

# Start client (foreground)
echo -e "${GREEN}[client]${NC} Starting Vite on :3000…"
(cd "${CLIENT_DIR}" && npm run dev) &
CLIENT_PID=$!

# Trap Ctrl+C to kill both
trap "echo ''; echo 'Shutting down…'; kill ${SERVER_PID} ${CLIENT_PID} 2>/dev/null; exit 0" INT TERM

echo ""
echo -e "  ${GREEN}✓${NC} Dashboard running at ${CYAN}http://localhost:3000${NC}"
echo "  Press Ctrl+C to stop."
echo ""

wait
