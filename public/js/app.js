/* JamAI — Main Application */

const API = '/api/tracks';

// ── State ─────────────────────────────────────────────────────
let tracks        = [];
let currentTrack  = null;
let animFrame     = null;
let waveAnimFrame = null;

// Form selections
const selections = {
  genre:       'electronic',
  mood:        'energetic',
  tempo:       'medium',
  duration:    '30',
  instruments: new Set()
};

// ── Init ──────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  setupNav();
  setupChipGroups();
  setupGenerateForm();
  setupPlayerControls();
  setupSearch();
  loadTracks();
});

// ── Navigation ────────────────────────────────────────────────
function setupNav() {
  document.querySelectorAll('.nav-item, .mobile-nav-item').forEach(item => {
    item.addEventListener('click', e => {
      e.preventDefault();
      switchView(item.dataset.view);
    });
  });
}

function switchView(view) {
  document.querySelectorAll('.nav-item, .mobile-nav-item').forEach(n => n.classList.toggle('active', n.dataset.view === view));
  document.getElementById('studioView').classList.toggle('hidden', view !== 'studio');
  document.getElementById('libraryView').classList.toggle('hidden', view !== 'library');
  if (view === 'library') renderTracks();
}

// ── Chip Groups ───────────────────────────────────────────────
function setupChipGroups() {
  setupSingleChipGroup('genreGroup', 'genre');
  setupSingleChipGroup('moodGroup', 'mood');
  setupSingleChipGroup('tempoGroup', 'tempo');
  setupSingleChipGroup('durationGroup', 'duration');

  // Instruments are multi-select toggles
  document.getElementById('instrumentsGroup').querySelectorAll('.chip.toggle').forEach(chip => {
    chip.addEventListener('click', () => {
      chip.classList.toggle('active');
      const v = chip.dataset.value;
      if (chip.classList.contains('active')) selections.instruments.add(v);
      else selections.instruments.delete(v);
    });
  });
}

function setupSingleChipGroup(groupId, selKey) {
  const group = document.getElementById(groupId);
  group.querySelectorAll('.chip').forEach(chip => {
    chip.addEventListener('click', () => {
      group.querySelectorAll('.chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      selections[selKey] = chip.dataset.value;
    });
  });
}

// ── Generate Form ─────────────────────────────────────────────
function setupGenerateForm() {
  const form = document.getElementById('generateForm');
  form.addEventListener('submit', async e => {
    e.preventDefault();
    const prompt = document.getElementById('promptInput').value.trim();
    if (!prompt) {
      document.getElementById('promptInput').focus();
      return;
    }
    await generateTrack(prompt);
  });
}

async function generateTrack(prompt) {
  const btn       = document.getElementById('generateBtn');
  const btnContent = btn.querySelector('.btn-content');
  const btnLoader  = document.getElementById('btnLoader');

  btn.disabled = true;
  btnContent.classList.add('hidden');
  btnLoader.classList.add('active');

  // Show generation animation
  showGeneratingState();

  try {
    const body = {
      prompt,
      genre:       selections.genre,
      mood:        selections.mood,
      tempo:       selections.tempo,
      duration:    parseInt(selections.duration),
      instruments: Array.from(selections.instruments)
    };

    const res   = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const track = await res.json();

    if (!res.ok) throw new Error(track.error || 'Generation failed');

    tracks.unshift(track);
    updateTrackCount();
    showPreviewTrack(track);

  } catch (err) {
    console.error(err);
    alert('Generation failed: ' + err.message);
    hideGeneratingState();
  } finally {
    btn.disabled = false;
    btnContent.classList.remove('hidden');
    btnLoader.classList.remove('active');
  }
}

function showGeneratingState() {
  const empty   = document.getElementById('previewEmpty');
  const player  = document.getElementById('previewPlayer');
  player.classList.add('hidden');
  empty.classList.remove('hidden');
  empty.innerHTML = `
    <div class="empty-waveform">
      <div class="empty-bars">
        ${Array(15).fill('<span></span>').join('')}
      </div>
    </div>
    <p style="color: var(--primary-2)">Composing your track…</p>
  `;
}

function hideGeneratingState() {
  const empty = document.getElementById('previewEmpty');
  empty.innerHTML = `
    <div class="empty-waveform"><div class="empty-bars">${Array(15).fill('<span></span>').join('')}</div></div>
    <p>Your generated track will appear here</p>
  `;
}

function showPreviewTrack(track) {
  const empty  = document.getElementById('previewEmpty');
  const player = document.getElementById('previewPlayer');

  empty.classList.add('hidden');
  player.classList.remove('hidden');

  player.innerHTML = `
    <div class="preview-track-header">
      <div class="preview-title">${escHtml(track.title)}</div>
      <div class="preview-chips">
        <span class="chip-tag genre-tag">${track.genre}</span>
        <span class="chip-tag mood-tag">${track.mood}</span>
        <span class="chip-tag tempo-tag">${track.tempo}</span>
      </div>
    </div>
    <div class="preview-waveform">
      <canvas id="previewCanvas" width="600" height="80"></canvas>
    </div>
    <button class="preview-play-btn" id="previewPlayBtn">
      <svg viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
      Play Track
    </button>
    <p style="font-size:0.75rem;color:var(--text-3);text-align:center;margin-top:8px;">
      ${track.prompt.length > 80 ? track.prompt.slice(0, 80) + '…' : track.prompt}
    </p>
  `;

  drawStaticWaveform(document.getElementById('previewCanvas'), track);

  document.getElementById('previewPlayBtn').addEventListener('click', () => {
    playTrack(track);
    switchView('library');
  });
}

// ── Track Loading ─────────────────────────────────────────────
async function loadTracks() {
  try {
    const res = await fetch(API);
    tracks = await res.json();
    updateTrackCount();
  } catch (err) {
    console.error('Failed to load tracks:', err);
  }
}

function updateTrackCount() {
  const label = `${tracks.length} track${tracks.length !== 1 ? 's' : ''}`;
  document.getElementById('trackCount').textContent = label;
  const mob = document.getElementById('trackCountMobile');
  if (mob) mob.textContent = label;
}

// ── Library Rendering ─────────────────────────────────────────
function setupSearch() {
  const searchInput  = document.getElementById('searchInput');
  const filterGenre  = document.getElementById('filterGenre');
  searchInput.addEventListener('input',  renderTracks);
  filterGenre.addEventListener('change', renderTracks);
}

function renderTracks() {
  const query     = document.getElementById('searchInput').value.toLowerCase();
  const genreFilter = document.getElementById('filterGenre').value;
  const grid      = document.getElementById('tracksGrid');
  const empty     = document.getElementById('tracksEmpty');

  const filtered = tracks.filter(t => {
    const matchesSearch = !query || t.title.toLowerCase().includes(query) || t.prompt.toLowerCase().includes(query);
    const matchesGenre  = !genreFilter || t.genre === genreFilter;
    return matchesSearch && matchesGenre;
  });

  // Clear existing cards (keep empty state element)
  Array.from(grid.children).forEach(el => {
    if (!el.id) el.remove();
  });

  if (filtered.length === 0) {
    empty.classList.remove('hidden');
    return;
  }

  empty.classList.add('hidden');

  const template = document.getElementById('trackCardTemplate');
  filtered.forEach(track => {
    const card = template.content.cloneNode(true).querySelector('.track-card');
    card.dataset.id = track.id;
    if (currentTrack && currentTrack.id === track.id) card.classList.add('playing');

    card.querySelector('.track-name').textContent    = track.title;
    card.querySelector('.track-prompt').textContent  = track.prompt;
    card.querySelector('.genre-tag').textContent     = track.genre;
    card.querySelector('.mood-tag').textContent      = track.mood;
    card.querySelector('.tempo-tag').textContent     = track.tempo;
    card.querySelector('.track-duration').textContent = formatTime(track.duration);
    card.querySelector('.track-plays').textContent   = `${track.plays || 0} plays`;
    card.querySelector('.track-date').textContent    = formatDate(track.createdAt);

    const canvas = card.querySelector('.mini-canvas');
    setTimeout(() => drawStaticWaveform(canvas, track), 50);

    card.querySelector('.play-btn').addEventListener('click', () => playTrack(track));
    card.querySelector('.delete-btn').addEventListener('click', () => deleteTrack(track.id));

    grid.appendChild(card);
  });
}

// ── Track Deletion ────────────────────────────────────────────
async function deleteTrack(id) {
  if (!confirm('Delete this track?')) return;
  try {
    await fetch(`${API}/${id}`, { method: 'DELETE' });
    tracks = tracks.filter(t => t.id !== id);
    updateTrackCount();
    if (currentTrack && currentTrack.id === id) {
      jamSynth.stop();
      currentTrack = null;
      updatePlayerBar(null);
    }
    renderTracks();
  } catch (err) {
    console.error(err);
  }
}

// ── Audio Playback ────────────────────────────────────────────
function playTrack(track) {
  if (currentTrack && currentTrack.id === track.id) {
    if (jamSynth.isPlaying) {
      jamSynth.stop();
      updatePlayPauseBtn(false);
      cancelAnimationFrame(animFrame);
      return;
    }
  }

  // Stop anything currently playing
  jamSynth.stop();
  cancelAnimationFrame(animFrame);

  currentTrack = track;

  // Increment play count
  fetch(`${API}/${track.id}/play`, { method: 'PATCH' }).then(() => {
    const t = tracks.find(t => t.id === track.id);
    if (t) t.plays = (t.plays || 0) + 1;
  });

  const vol = parseFloat(document.getElementById('volumeSlider').value);

  jamSynth.onEnd = () => {
    updatePlayPauseBtn(false);
    cancelAnimationFrame(animFrame);
    document.getElementById('progressFill').style.width = '0%';
    document.getElementById('currentTime').textContent = '0:00';
  };

  jamSynth.play(track.synthParams, track.duration, vol);

  updatePlayerBar(track);
  updatePlayPauseBtn(true);
  startProgressLoop();
  startWaveformLoop();

  // Update card states
  document.querySelectorAll('.track-card').forEach(card => {
    card.classList.toggle('playing', card.dataset.id === track.id);
  });
}

function startProgressLoop() {
  function loop() {
    if (!jamSynth.isPlaying) return;
    const progress = jamSynth.getProgress();
    const elapsed  = jamSynth.getElapsed();
    document.getElementById('progressFill').style.width = (progress * 100) + '%';
    document.getElementById('currentTime').textContent  = formatTime(Math.floor(elapsed));
    animFrame = requestAnimationFrame(loop);
  }
  animFrame = requestAnimationFrame(loop);
}

function startWaveformLoop() {
  const canvas  = document.getElementById('waveformCanvas');
  const ctx     = canvas.getContext('2d');
  const analyser = jamSynth.getAnalyser();
  if (!analyser) return;

  const bufLen  = analyser.frequencyBinCount;
  const dataArr = new Uint8Array(bufLen);

  function loop() {
    if (!jamSynth.isPlaying) {
      // Draw flat line when stopped
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      return;
    }
    analyser.getByteTimeDomainData(dataArr);

    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.lineWidth   = 1.5;
    ctx.strokeStyle = 'rgba(124,58,237,0.8)';
    ctx.beginPath();

    const sliceW = canvas.width / bufLen;
    let x = 0;
    for (let i = 0; i < bufLen; i++) {
      const v = dataArr[i] / 128.0;
      const y = (v * canvas.height) / 2;
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      x += sliceW;
    }
    ctx.stroke();
    waveAnimFrame = requestAnimationFrame(loop);
  }
  waveAnimFrame = requestAnimationFrame(loop);
}

// ── Player Bar ────────────────────────────────────────────────
function updatePlayerBar(track) {
  const title = document.getElementById('playerTitle');
  const tags  = document.getElementById('playerTags');
  const total = document.getElementById('totalTime');

  if (!track) {
    title.textContent = '—';
    tags.textContent  = '';
    total.textContent = '0:00';
    return;
  }

  title.textContent = track.title;
  tags.textContent  = `${track.genre} · ${track.mood} · ${track.tempo}`;
  total.textContent = formatTime(track.duration);
}

function setupPlayerControls() {
  document.getElementById('playPauseBtn').addEventListener('click', () => {
    if (!currentTrack) return;
    if (jamSynth.isPlaying) {
      jamSynth.stop();
      updatePlayPauseBtn(false);
      cancelAnimationFrame(animFrame);
    } else {
      playTrack(currentTrack);
    }
  });

  document.getElementById('stopBtn').addEventListener('click', () => {
    jamSynth.stop();
    updatePlayPauseBtn(false);
    cancelAnimationFrame(animFrame);
    document.getElementById('progressFill').style.width = '0%';
    document.getElementById('currentTime').textContent = '0:00';
    document.querySelectorAll('.track-card.playing').forEach(c => c.classList.remove('playing'));
  });

  document.getElementById('volumeSlider').addEventListener('input', e => {
    jamSynth.setVolume(parseFloat(e.target.value));
  });

  document.getElementById('progressBar').addEventListener('click', e => {
    // Seeking is not supported for procedural synth, but keep UI hint
  });
}

function updatePlayPauseBtn(playing) {
  const btn = document.getElementById('playPauseBtn');
  btn.classList.toggle('playing', playing);
  btn.querySelector('.icon-play').classList.toggle('hidden', playing);
  btn.querySelector('.icon-pause').classList.toggle('hidden', !playing);
}

// ── Static Waveform Drawing ───────────────────────────────────
function drawStaticWaveform(canvas, track) {
  if (!canvas) return;
  const ctx    = canvas.getContext('2d');
  const w      = canvas.width;
  const h      = canvas.height;
  const bars   = Math.floor(w / 4);

  // Seed a deterministic-ish wave from track id
  const seed   = track.id ? track.id.split('').reduce((a, c) => a + c.charCodeAt(0), 0) : 42;
  const rng    = seededRand(seed);

  ctx.clearRect(0, 0, w, h);

  const grad = ctx.createLinearGradient(0, 0, w, 0);
  grad.addColorStop(0,   'rgba(124,58,237,0.6)');
  grad.addColorStop(0.5, 'rgba(236,72,153,0.8)');
  grad.addColorStop(1,   'rgba(124,58,237,0.6)');
  ctx.fillStyle = grad;

  for (let i = 0; i < bars; i++) {
    const amp = 0.2 + rng() * 0.8;
    const bh  = amp * (h * 0.8);
    const x   = i * (w / bars);
    const bw  = (w / bars) - 1;
    ctx.fillRect(x, (h - bh) / 2, bw, bh);
  }
}

function seededRand(seed) {
  let s = seed;
  return () => {
    s = (s * 1664525 + 1013904223) & 0xffffffff;
    return ((s >>> 0) / 0xffffffff);
  };
}

// ── Utilities ─────────────────────────────────────────────────
function formatTime(sec) {
  const s = Math.floor(sec) || 0;
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function formatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function escHtml(str) {
  return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
