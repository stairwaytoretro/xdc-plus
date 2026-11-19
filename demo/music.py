"""Tiny procedural chiptune synth (original music for the XDC-Plus demos).
Pulse leads, stepped triangle bass, noise drums, fast arpeggios. 11040 Hz."""
import numpy as np
from scipy.signal import lfilter
SR = 11040
NOTE = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}

def midi(n):
    if isinstance(n, (int, np.integer)): return int(n)
    b = NOTE[n[0]]; i = 1
    while n[i] in '#b':
        b += 1 if n[i] == '#' else -1; i += 1
    return b + 12 * (int(n[i:]) + 1)

def hz(m): return 440.0 * 2 ** ((m - 69) / 12)

def env(n, a=0.004, d=0.08, s=0.6, r=0.03):
    t = np.arange(n) / SR
    e = np.where(t < a, t / a, s + (1 - s) * np.exp(-(t - a) / d))
    rn = int(r * SR)
    if rn and n > rn: e[-rn:] *= np.linspace(1, 0, rn)
    return e

def osc_pulse(f, n, duty=0.5, vib=0.0, vib_hz=5.5, vib_delay=0.15):
    t = np.arange(n) / SR
    fm = f * (1 + vib * np.sin(2 * np.pi * vib_hz * t) * (t > vib_delay))
    ph = np.cumsum(fm) / SR % 1.0
    return np.where(ph < duty, 1.0, -1.0)

def osc_tri(f, n):
    ph = (np.arange(n) * f / SR) % 1.0
    tri = 1 - 4 * np.abs(ph - 0.5)
    return np.round(tri * 7.5) / 7.5          # 4-bit stepped, NES-like

_rng = np.random.default_rng(1234)
def noise(n): return _rng.uniform(-1, 1, n)

class Song:
    def __init__(self, bpm, seconds):
        self.bpm = bpm; self.beat = 60.0 / bpm
        self.n = int(round(seconds * SR)); self.tracks = {}
    def buf(self, name):
        if name not in self.tracks: self.tracks[name] = np.zeros(self.n + SR)
        return self.tracks[name]
    def add(self, name, t, sig):
        b = self.buf(name); i = int(round(t * SR)); j = min(len(b), i + len(sig))
        if j > i: b[i:j] += sig[:j - i]
    # instruments -----------------------------------------------------
    def lead(self, t, dur, note, vol=0.30, duty=0.25, vib=0.006, name='lead', d=0.25, s=0.55):
        n = int(dur * SR); f = hz(midi(note))
        self.add(name, t, vol * osc_pulse(f, n, duty, vib) * env(n, d=d, s=s))
    def bass(self, t, dur, note, vol=0.45):
        n = int(dur * SR)
        self.add('bass', t, vol * osc_tri(hz(midi(note)), n) * env(n, a=0.002, d=0.12, s=0.7, r=0.015))
    def arp(self, t, dur, notes, vol=0.12, step=1 / 30, duty=0.125):
        n = int(dur * SR); ms = [midi(x) for x in notes]
        k = (np.arange(n) / SR / step).astype(int) % len(ms)
        f = np.array([hz(m) for m in ms])[k]
        ph = np.cumsum(f) / SR % 1.0
        self.add('arp', t, vol * np.where(ph < duty, 1.0, -1.0) * env(n, d=0.3, s=0.7, r=0.02))
    def kick(self, t, vol=0.8):
        n = int(0.16 * SR); tt = np.arange(n) / SR
        f = 45 + 120 * np.exp(-tt / 0.025)
        self.add('drums', t, vol * np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / 0.06))
    def snare(self, t, vol=0.45):
        n = int(0.14 * SR); tt = np.arange(n) / SR
        s = 0.75 * noise(n) * np.exp(-tt / 0.045) + 0.5 * np.sin(2 * np.pi * 190 * tt) * np.exp(-tt / 0.03)
        self.add('drums', t, vol * s)
    def hat(self, t, vol=0.14, open_=False):
        n = int((0.12 if open_ else 0.035) * SR); tt = np.arange(n) / SR
        x = noise(n); x = np.diff(np.r_[0, x])          # brighter
        self.add('drums', t, vol * x * np.exp(-tt / (0.04 if open_ else 0.01)))
    def click(self, t, vol=0.35):
        n = int(0.012 * SR); tt = np.arange(n) / SR
        x = np.diff(np.r_[0, noise(n)])
        self.add('fx', t, vol * x * np.exp(-tt / 0.003))
    def bars(self, t0, bars, steps=8, fn=None):
        pass
    # melody from bar strings (8 eighth-note tokens per bar) ----------
    def melody(self, t0, bars, **kw):
        step = self.beat / 2; toks = []
        for b in bars: toks += b.split()
        i = 0
        while i < len(toks):
            tk = toks[i]
            if tk in '.-': i += 1; continue
            j = i + 1
            while j < len(toks) and toks[j] == '-': j += 1
            self.lead(t0 + i * step, (j - i) * step * 0.95, tk, **kw); i = j
    def mix(self, gains=None, lp_hz=4200, fade_in=0.0, fade_out=0.0, end_at=None, drive=1.8):
        gains = gains or {}
        x = sum(gains.get(k, 1.0) * v for k, v in self.tracks.items())[:self.n]
        a = 1 - np.exp(-2 * np.pi * lp_hz / SR)
        x = lfilter([a], [1, a - 1], x)
        x = lfilter([1, -1], [1, -0.995], x)          # DC block
        if fade_in: k = int(fade_in * SR); x[:k] *= np.linspace(0, 1, k)
        if end_at is not None:
            e = int(end_at * SR); x[e:] = 0
            if fade_out: k = int(fade_out * SR); x[e - k:e] *= np.linspace(1, 0, k) ** 2
        x = x / (np.abs(x).max() + 1e-9)
        x = np.tanh(drive * x) / np.tanh(drive)       # gentle limiter: louder 8-bit output
        return x * 0.95

def to_u8(x):
    return np.clip(np.round(x * 127 + 128), 1, 255).astype(np.uint8)

def wav_bytes(pcm):
    import struct
    pcm = bytes(pcm)
    return struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16, 1, 1,
                       SR, SR, 1, 8, b"data", len(pcm)) + pcm
