const router  = require('express').Router();
const multer  = require('multer');
const path    = require('path');
const { getSession } = require('../services/neo4j');
const { importCSV }  = require('../services/csvParser');
const {
  getFullGraph,
  findShortestPath,
  getInfluenceScores,
  getCommunities,
  getNetworkStats,
  getAllPersonNames,
} = require('../services/graphAnalysis');

const upload = multer({
  dest: path.join(__dirname, '..', 'uploads'),
  limits: { fileSize: 25 * 1024 * 1024 },   // 25 MB max
  fileFilter(req, file, cb) {
    if (!file.originalname.match(/\.csv$/i)) {
      return cb(new Error('Only CSV files are accepted'));
    }
    cb(null, true);
  },
});

// ---------------------------------------------------------------------------
// Health / stats
// ---------------------------------------------------------------------------

router.get('/health', async (req, res) => {
  try {
    const session = getSession();
    await session.run('RETURN 1');
    await session.close();
    res.json({ status: 'ok', neo4j: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'error', neo4j: err.message });
  }
});

router.get('/stats', async (req, res) => {
  try {
    res.json(await getNetworkStats());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// People (for dropdowns)
// ---------------------------------------------------------------------------

router.get('/people', async (req, res) => {
  try {
    res.json(await getAllPersonNames());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// CSV upload & import
// ---------------------------------------------------------------------------

router.post('/upload', upload.single('csv'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No CSV file uploaded' });
  try {
    const results = await importCSV(req.file.path);
    res.json(results);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Full graph data
// ---------------------------------------------------------------------------

router.get('/graph', async (req, res) => {
  try {
    const options = {
      nodeTypes: req.query.nodeTypes ? req.query.nodeTypes.split(',') : null,
      relTypes:  req.query.relTypes  ? req.query.relTypes.split(',')  : null,
      limit:     parseInt(req.query.limit) || 1000,
    };
    res.json(await getFullGraph(options));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Analysis: shortest path
// ---------------------------------------------------------------------------

router.get('/analysis/shortest-path', async (req, res) => {
  const { from, to } = req.query;
  if (!from || !to) {
    return res.status(400).json({ error: '"from" and "to" query params are required' });
  }
  try {
    res.json(await findShortestPath(from, to));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Analysis: influence / degree centrality
// ---------------------------------------------------------------------------

router.get('/analysis/influence', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    res.json(await getInfluenceScores(limit));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Analysis: community detection
// ---------------------------------------------------------------------------

router.get('/analysis/communities', async (req, res) => {
  try {
    res.json(await getCommunities());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Clear all data (admin)
// ---------------------------------------------------------------------------

router.delete('/data', async (req, res) => {
  try {
    const session = getSession();
    await session.run('MATCH (n) DETACH DELETE n');
    await session.close();
    res.json({ success: true, message: 'All graph data cleared' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
