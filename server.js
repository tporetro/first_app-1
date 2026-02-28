require('dotenv').config();

const express = require('express');
const path    = require('path');
const { verifyConnection, initializeSchema } = require('./services/neo4j');
const apiRoutes = require('./routes/api');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.use('/api', apiRoutes);

// SPA fallback for direct page loads
app.get('*', (req, res) => {
  const pages = ['graph', 'upload', 'analysis'];
  const page  = req.path.replace(/^\//, '');
  const file  = pages.includes(page) ? `${page}.html` : 'index.html';
  res.sendFile(path.join(__dirname, 'public', file));
});

(async () => {
  await verifyConnection();
  await initializeSchema();

  app.listen(PORT, () => {
    console.log(`Neo4j Owner Network running at http://localhost:${PORT}`);
  });
})();
