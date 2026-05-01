/* JamAI — Web Audio Synthesizer
 * Generates real music using the Web Audio API based on genre/mood/tempo params.
 */

class JamSynth {
  constructor() {
    this.ctx = null;
    this.masterGain = null;
    this.analyser = null;
    this.scheduledNodes = [];
    this.isPlaying = false;
    this.startTime = 0;
    this.duration = 30;
    this.onEnd = null;
  }

  _ensureContext() {
    if (!this.ctx) {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      this.masterGain = this.ctx.createGain();
      this.analyser = this.ctx.createAnalyser();
      this.analyser.fftSize = 256;
      this.masterGain.connect(this.analyser);
      this.analyser.connect(this.ctx.destination);
    }
    if (this.ctx.state === 'suspended') this.ctx.resume();
  }

  setVolume(v) {
    if (this.masterGain) this.masterGain.gain.setTargetAtTime(v, this.ctx.currentTime, 0.01);
  }

  stop() {
    this.isPlaying = false;
    this.scheduledNodes.forEach(n => { try { n.stop(); } catch(e) {} });
    this.scheduledNodes = [];
  }

  // Returns a frequency for a note in the given scale at the given octave
  _noteFreq(root, scale, degree, octave = 0) {
    const semitones = scale[degree % scale.length] + Math.floor(degree / scale.length) * 12;
    return root * Math.pow(2, (semitones + octave * 12) / 12);
  }

  // Build a simple reverb via delay network
  _makeReverb(amount) {
    const conv = this.ctx.createConvolver();
    const rate = this.ctx.sampleRate;
    const len  = rate * 2.5;
    const buf  = this.ctx.createBuffer(2, len, rate);
    for (let ch = 0; ch < 2; ch++) {
      const data = buf.getChannelData(ch);
      for (let i = 0; i < len; i++) {
        data[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 2);
      }
    }
    conv.buffer = buf;
    const wet = this.ctx.createGain();
    const dry = this.ctx.createGain();
    wet.gain.value = amount;
    dry.gain.value = 1 - amount * 0.5;
    return { conv, wet, dry };
  }

  _scheduleNote(freq, startAt, duration, waveform, gainVal, filterFreq) {
    const osc  = this.ctx.createOscillator();
    const gain = this.ctx.createGain();
    const filt = this.ctx.createBiquadFilter();

    osc.type = waveform || 'sawtooth';
    osc.frequency.value = freq;

    filt.type = 'lowpass';
    filt.frequency.value = filterFreq || 2000;
    filt.Q.value = 0.8;

    gain.gain.setValueAtTime(0, startAt);
    gain.gain.linearRampToValueAtTime(gainVal, startAt + 0.02);
    gain.gain.setValueAtTime(gainVal, startAt + duration - 0.05);
    gain.gain.linearRampToValueAtTime(0, startAt + duration);

    osc.connect(filt);
    filt.connect(gain);
    gain.connect(this.masterGain);

    osc.start(startAt);
    osc.stop(startAt + duration + 0.05);
    this.scheduledNodes.push(osc);
  }

  _scheduleChord(freqs, startAt, duration, waveform, gainVal, filterFreq) {
    freqs.forEach((f, i) => {
      const detune = (i - freqs.length / 2) * 4;
      const osc  = this.ctx.createOscillator();
      const gain = this.ctx.createGain();
      const filt = this.ctx.createBiquadFilter();

      osc.type = waveform || 'sawtooth';
      osc.frequency.value = f;
      osc.detune.value = detune;

      filt.type = 'lowpass';
      filt.frequency.value = filterFreq || 2000;
      filt.Q.value = 1.2;

      gain.gain.setValueAtTime(0, startAt);
      gain.gain.linearRampToValueAtTime(gainVal, startAt + 0.08);
      gain.gain.setValueAtTime(gainVal * 0.8, startAt + duration - 0.1);
      gain.gain.linearRampToValueAtTime(0, startAt + duration + 0.1);

      osc.connect(filt);
      filt.connect(gain);
      gain.connect(this.masterGain);

      osc.start(startAt);
      osc.stop(startAt + duration + 0.2);
      this.scheduledNodes.push(osc);
    });
  }

  _scheduleBass(freq, startAt, duration) {
    const osc  = this.ctx.createOscillator();
    const gain = this.ctx.createGain();
    const filt = this.ctx.createBiquadFilter();

    osc.type = 'sine';
    osc.frequency.value = freq;

    filt.type = 'lowpass';
    filt.frequency.value = 280;

    gain.gain.setValueAtTime(0, startAt);
    gain.gain.linearRampToValueAtTime(0.35, startAt + 0.01);
    gain.gain.setValueAtTime(0.3, startAt + duration - 0.05);
    gain.gain.linearRampToValueAtTime(0, startAt + duration);

    osc.connect(filt);
    filt.connect(gain);
    gain.connect(this.masterGain);

    osc.start(startAt);
    osc.stop(startAt + duration + 0.05);
    this.scheduledNodes.push(osc);
  }

  _scheduleKick(startAt) {
    const osc  = this.ctx.createOscillator();
    const gain = this.ctx.createGain();

    osc.type = 'sine';
    osc.frequency.setValueAtTime(160, startAt);
    osc.frequency.exponentialRampToValueAtTime(40, startAt + 0.06);

    gain.gain.setValueAtTime(0.7, startAt);
    gain.gain.exponentialRampToValueAtTime(0.001, startAt + 0.25);

    osc.connect(gain);
    gain.connect(this.masterGain);

    osc.start(startAt);
    osc.stop(startAt + 0.3);
    this.scheduledNodes.push(osc);
  }

  _scheduleSnare(startAt) {
    // Noise burst
    const buf  = this.ctx.createBuffer(1, this.ctx.sampleRate * 0.15, this.ctx.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;

    const src  = this.ctx.createBufferSource();
    const gain = this.ctx.createGain();
    const filt = this.ctx.createBiquadFilter();

    src.buffer = buf;
    filt.type = 'bandpass';
    filt.frequency.value = 3000;
    filt.Q.value = 0.5;

    gain.gain.setValueAtTime(0.25, startAt);
    gain.gain.exponentialRampToValueAtTime(0.001, startAt + 0.12);

    src.connect(filt);
    filt.connect(gain);
    gain.connect(this.masterGain);

    src.start(startAt);
    src.stop(startAt + 0.15);
    this.scheduledNodes.push(src);

    // Tone body
    const tone = this.ctx.createOscillator();
    const tGain = this.ctx.createGain();
    tone.type = 'triangle';
    tone.frequency.value = 220;
    tGain.gain.setValueAtTime(0.08, startAt);
    tGain.gain.exponentialRampToValueAtTime(0.001, startAt + 0.08);
    tone.connect(tGain);
    tGain.connect(this.masterGain);
    tone.start(startAt);
    tone.stop(startAt + 0.1);
    this.scheduledNodes.push(tone);
  }

  _scheduleHihat(startAt, closed = true) {
    const buf  = this.ctx.createBuffer(1, this.ctx.sampleRate * 0.05, this.ctx.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;

    const src  = this.ctx.createBufferSource();
    const gain = this.ctx.createGain();
    const filt = this.ctx.createBiquadFilter();

    src.buffer = buf;
    filt.type = 'highpass';
    filt.frequency.value = closed ? 8000 : 6000;

    gain.gain.setValueAtTime(0.12, startAt);
    gain.gain.exponentialRampToValueAtTime(0.001, startAt + (closed ? 0.04 : 0.12));

    src.connect(filt);
    filt.connect(gain);
    gain.connect(this.masterGain);
    src.start(startAt);
    src.stop(startAt + 0.15);
    this.scheduledNodes.push(src);
  }

  // Build chord frequencies from a root, scale, and chord degree
  _chordFreqs(root, scale, chordRoot, octave = 0) {
    const rootFreq = this._noteFreq(root, scale, chordRoot, octave - 1);
    return [
      rootFreq,
      this._noteFreq(root, scale, chordRoot + 2, octave - 1),
      this._noteFreq(root, scale, chordRoot + 4, octave - 1),
    ];
  }

  play(params, duration, volume = 0.7) {
    this._ensureContext();
    this.stop();

    this.duration = duration;
    this.isPlaying = true;
    this.startTime = this.ctx.currentTime + 0.1;
    this.masterGain.gain.value = volume;

    const {
      bpm, root, scale, progression, filterFreq,
      hasDrums, hasBass, waveform
    } = params;

    const beatDur   = 60 / bpm;
    const barDur    = beatDur * 4;
    const totalBars = Math.ceil(duration / barDur);

    for (let bar = 0; bar < totalBars; bar++) {
      const barStart  = this.startTime + bar * barDur;
      const chordIdx  = progression[bar % progression.length];

      // ── Chords / Pad ─────────────────────────────────────────
      const chordFreqs = this._chordFreqs(root, scale, chordIdx, 1);
      const chordGain  = waveform === 'sine' ? 0.08 : 0.06;
      this._scheduleChord(chordFreqs, barStart, barDur * 0.95, waveform, chordGain, filterFreq);

      // ── Melody ───────────────────────────────────────────────
      const melNotes = [0, 2, 4, 7, 9, 11, 12, 14];
      const notesPerBar = bpm >= 120 ? 8 : bpm >= 90 ? 6 : 4;
      const noteDur = barDur / notesPerBar;

      for (let n = 0; n < notesPerBar; n++) {
        if (Math.random() < 0.3) continue;
        const noteIdx = melNotes[Math.floor(Math.random() * melNotes.length)];
        const freq    = this._noteFreq(root, scale, chordIdx + noteIdx, 1);
        const t       = barStart + n * noteDur;
        this._scheduleNote(freq, t, noteDur * 0.7, 'triangle', 0.04, filterFreq * 1.5);
      }

      // ── Bass ─────────────────────────────────────────────────
      if (hasBass) {
        const bassFreq = this._noteFreq(root, scale, chordIdx, -1);
        this._scheduleBass(bassFreq, barStart, beatDur * 0.8);
        this._scheduleBass(bassFreq, barStart + beatDur * 2, beatDur * 0.8);
        if (bpm >= 100) {
          this._scheduleBass(bassFreq, barStart + beatDur * 2.5, beatDur * 0.4);
        }
      }

      // ── Drums ────────────────────────────────────────────────
      if (hasDrums) {
        // Kick on 1 and 3
        this._scheduleKick(barStart);
        this._scheduleKick(barStart + beatDur * 2);

        // Snare on 2 and 4
        this._scheduleSnare(barStart + beatDur);
        this._scheduleSnare(barStart + beatDur * 3);

        // Hi-hats: 8th notes
        for (let h = 0; h < 8; h++) {
          const open = h === 2 || h === 6;
          if (Math.random() < 0.85) {
            this._scheduleHihat(barStart + h * beatDur * 0.5, !open);
          }
        }
      }
    }

    // Fade out at end
    this.masterGain.gain.setValueAtTime(volume, this.startTime + duration - 2);
    this.masterGain.gain.linearRampToValueAtTime(0, this.startTime + duration);

    // Notify when done
    if (this.onEnd) {
      const endTime = (this.startTime + duration - this.ctx.currentTime) * 1000;
      this._endTimer = setTimeout(() => {
        this.isPlaying = false;
        if (this.onEnd) this.onEnd();
      }, Math.max(endTime, 0));
    }
  }

  getAnalyser() { return this.analyser; }

  getProgress() {
    if (!this.isPlaying || !this.ctx) return 0;
    const elapsed = this.ctx.currentTime - this.startTime;
    return Math.min(elapsed / this.duration, 1);
  }

  getElapsed() {
    if (!this.ctx) return 0;
    return Math.max(0, this.ctx.currentTime - this.startTime);
  }
}

window.jamSynth = new JamSynth();
