const express = require('express');
const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

const app = express();
const PORT = process.env.PORT || 3000;
const DB_FILE = path.join(__dirname, 'data', 'tracks.json');

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

function readTracks() {
  if (!fs.existsSync(DB_FILE)) {
    fs.writeFileSync(DB_FILE, JSON.stringify([]));
    return [];
  }
  try {
    return JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
  } catch {
    return [];
  }
}

function writeTracks(tracks) {
  fs.writeFileSync(DB_FILE, JSON.stringify(tracks, null, 2));
}

app.get('/api/tracks', (req, res) => {
  const tracks = readTracks();
  res.json(tracks.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)));
});

app.post('/api/tracks', (req, res) => {
  const { title, prompt, genre, mood, tempo, duration, instruments } = req.body;
  if (!prompt) return res.status(400).json({ error: 'Prompt is required' });

  const track = {
    id: randomUUID(),
    title: title || generateTitle(prompt, genre, mood),
    prompt,
    genre: genre || 'electronic',
    mood: mood || 'energetic',
    tempo: tempo || 'medium',
    duration: parseInt(duration) || 30,
    instruments: instruments || [],
    status: 'complete',
    plays: 0,
    createdAt: new Date().toISOString(),
    synthParams: buildSynthParams(genre, mood, tempo)
  };

  const tracks = readTracks();
  tracks.push(track);
  writeTracks(tracks);
  res.status(201).json(track);
});

app.patch('/api/tracks/:id/play', (req, res) => {
  const tracks = readTracks();
  const track = tracks.find(t => t.id === req.params.id);
  if (!track) return res.status(404).json({ error: 'Track not found' });
  track.plays = (track.plays || 0) + 1;
  writeTracks(tracks);
  res.json(track);
});

app.delete('/api/tracks/:id', (req, res) => {
  const tracks = readTracks();
  const index = tracks.findIndex(t => t.id === req.params.id);
  if (index === -1) return res.status(404).json({ error: 'Track not found' });
  tracks.splice(index, 1);
  writeTracks(tracks);
  res.status(204).send();
});

function generateTitle(prompt, genre, mood) {
  const words = prompt.split(' ').filter(w => w.length > 3);
  const keyword = words[Math.floor(Math.random() * words.length)] || 'Untitled';
  const adjectives = {
    happy: ['Bright', 'Sunny', 'Golden'], melancholic: ['Fading', 'Hollow', 'Lost'],
    energetic: ['Electric', 'Blazing', 'Surge'], calm: ['Drifting', 'Quiet', 'Still'],
    epic: ['Infinite', 'Titan', 'Rising'], nostalgic: ['Memory', 'Echo', 'Vintage'],
    dark: ['Shadow', 'Void', 'Abyss'], romantic: ['Tender', 'Velvet', 'Crimson']
  };
  const adj = (adjectives[mood] || ['Unknown'])[Math.floor(Math.random() * 3)];
  return `${adj} ${keyword.charAt(0).toUpperCase() + keyword.slice(1)}`;
}

function buildSynthParams(genre, mood, tempo) {
  const tempoMap = { slow: 70, medium: 100, fast: 130 };
  const bpm = tempoMap[tempo] || 100;

  const scaleMap = {
    happy: [0, 2, 4, 5, 7, 9, 11], energetic: [0, 2, 4, 5, 7, 9, 11],
    melancholic: [0, 2, 3, 5, 7, 8, 10], calm: [0, 2, 3, 5, 7, 8, 10],
    epic: [0, 2, 3, 5, 7, 9, 10], nostalgic: [0, 2, 3, 5, 7, 8, 10],
    dark: [0, 1, 3, 5, 6, 8, 10], romantic: [0, 2, 4, 5, 7, 9, 11]
  };

  const progressionMap = {
    pop: [0, 4, 5, 3], electronic: [0, 5, 3, 4], rock: [0, 3, 4, 0],
    jazz: [1, 4, 0, 5], ambient: [0, 2, 4, 2], 'lo-fi': [0, 5, 3, 4],
    classical: [0, 3, 4, 0], 'hip-hop': [0, 5, 3, 4], default: [0, 4, 5, 3]
  };

  const rootNotes = { C: 261.63, D: 293.66, E: 329.63, F: 349.23, G: 392.00, A: 440.00, B: 493.88 };
  const rootKeys = Object.keys(rootNotes);
  const root = rootNotes[rootKeys[Math.floor(Math.random() * rootKeys.length)]];

  return {
    bpm,
    root,
    scale: scaleMap[mood] || scaleMap.happy,
    progression: progressionMap[genre] || progressionMap.default,
    filterFreq: genre === 'ambient' ? 800 : genre === 'electronic' ? 3000 : 2000,
    reverbAmount: genre === 'ambient' ? 0.8 : genre === 'jazz' ? 0.4 : 0.2,
    hasDrums: !['ambient', 'classical'].includes(genre),
    hasBass: !['ambient', 'classical'].includes(genre),
    waveform: genre === 'electronic' ? 'sawtooth' : genre === 'ambient' ? 'sine' : 'triangle'
  };
}

app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`JamAI running at http://localhost:${PORT}`);
});
