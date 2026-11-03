"""Synthesise five original, royalty-free looping tunes for CRS Memories.

Every sound is generated from scratch (additive tones, Karplus-Strong plucks,
noise drums, FFT-convolution reverb), so there is nothing licensed in them.
Each loop is an exact number of bars and its reverb tail is folded back onto
its start, so the app can loop it without a click or a gap.
"""
import numpy as np
import subprocess, sys, os

SR = 44100
rng = np.random.default_rng(7)
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)

NOTE = {n: i for i, n in enumerate(["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"])}

def hz(name):
    """'A4' -> 440."""
    pitch, octave = name[:-1], int(name[-1])
    midi = 12 * (octave + 1) + NOTE[pitch]
    return 440.0 * 2 ** ((midi - 69) / 12)

def env_adsr(n, a, d, s, r, sr=SR):
    a, d, r = int(a * sr), int(d * sr), int(r * sr)
    sus = max(n - a - d - r, 0)
    e = np.concatenate([
        np.linspace(0, 1, max(a, 1), endpoint=False),
        np.linspace(1, s, max(d, 1), endpoint=False),
        np.full(sus, s),
        np.linspace(s, 0, max(r, 1)),
    ])
    return e[:n] if len(e) >= n else np.pad(e, (0, n - len(e)))

def lowpass(x, cutoff):
    """One-pole lowpass, vectorised through FFT magnitude shaping."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / np.sqrt(1 + (f / cutoff) ** 4)
    return np.fft.irfft(X, len(x))

def highpass(x, cutoff):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= (f / cutoff) ** 2 / np.sqrt(1 + (f / cutoff) ** 4)
    return np.fft.irfft(X, len(x))

# ---------- instruments ----------

def piano(freq, dur, vel=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, 9):
        f = freq * k * np.sqrt(1 + 0.0004 * k * k)
        if f > SR / 2.2:
            break
        decay = 1.2 + 0.9 * k
        out += (1 / k ** 1.6) * np.sin(2 * np.pi * f * t + rng.uniform(0, 6)) * np.exp(-t * decay * (freq / 440) ** 0.3)
    attack = np.minimum(t / 0.004, 1)
    release = env_adsr(n, 0.001, 0.0, 1.0, 0.25)
    return out * attack * release * vel * 0.5

def rhodes(freq, dur, vel=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    mod = np.sin(2 * np.pi * freq * t) * 1.3 * np.exp(-t * 3)
    tone = np.sin(2 * np.pi * freq * t + mod) + 0.2 * np.sin(2 * np.pi * 2 * freq * t)
    trem = 1 + 0.12 * np.sin(2 * np.pi * 4.5 * t)
    return tone * np.exp(-t * 1.4) * trem * env_adsr(n, 0.003, 0, 1, 0.2) * vel * 0.35

def pad(freq, dur, vel=1.0, bright=1800):
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for detune in (-0.12, -0.04, 0.05, 0.11):
        f = freq * 2 ** (detune / 12)
        phase = (f * t + rng.uniform()) % 1.0
        out += 2 * phase - 1                       # saw
    out = lowpass(out, bright)
    return out * env_adsr(n, min(1.2, dur / 3), 0.3, 0.8, min(1.5, dur / 3)) * vel * 0.12

def strings(freq, dur, vel=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    vib = 1 + 0.004 * np.sin(2 * np.pi * 5.2 * t)
    out = np.zeros(n)
    for detune in (-0.07, 0.0, 0.08):
        ph = np.cumsum(freq * 2 ** (detune / 12) * vib) / SR
        out += 2 * (ph % 1.0) - 1
    out = lowpass(out, 2600)
    return out * env_adsr(n, min(0.9, dur / 3), 0.2, 0.85, min(1.2, dur / 3)) * vel * 0.1

def pluck(freq, dur, vel=1.0, damp=0.996):
    n = int(dur * SR)
    period = int(SR / freq)
    buf = rng.uniform(-1, 1, period)
    out = np.empty(n)
    # Karplus-Strong, a period at a time.
    pos = 0
    while pos < n:
        take = min(period, n - pos)
        out[pos:pos + take] = buf[:take]
        buf = damp * 0.5 * (buf + np.roll(buf, -1))
        pos += take
    return lowpass(out, 5000) * env_adsr(n, 0.001, 0, 1, 0.08) * vel * 0.5

def bass(freq, dur, vel=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    tone = np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * 2 * freq * t)
    return np.tanh(1.6 * tone) * env_adsr(n, 0.005, 0.1, 0.7, 0.06) * vel * 0.45

def kick(vel=1.0):
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 45 + 95 * np.exp(-t * 28)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 9) * vel * 0.9

def snare(vel=1.0):
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    noise = lowpass(highpass(rng.uniform(-1, 1, n), 1500), 8000) * np.exp(-t * 22)
    body = np.sin(2 * np.pi * 185 * t) * np.exp(-t * 30)
    return (0.6 * noise + 0.5 * body) * vel * 0.55

def hat(vel=1.0, open_=False):
    n = int((0.25 if open_ else 0.06) * SR)
    t = np.arange(n) / SR
    return highpass(rng.uniform(-1, 1, n), 7000) * np.exp(-t * (12 if open_ else 70)) * vel * 0.11

def timpani(freq, vel=1.0):
    n = int(1.8 * SR)
    t = np.arange(n) / SR
    tone = np.sin(2 * np.pi * freq * t) + 0.4 * np.sin(2 * np.pi * freq * 1.5 * t)
    noise = lowpass(rng.uniform(-1, 1, n), 400) * np.exp(-t * 30)
    return (tone * np.exp(-t * 2.2) + noise) * vel * 0.4

# ---------- arrangement helpers ----------

class Track:
    def __init__(self, bars, bpm, beats=4):
        self.beat = 60 / bpm
        self.length = int(bars * beats * self.beat * SR)
        self.tail = int(3.5 * SR)
        self.L = np.zeros(self.length + self.tail)
        self.R = np.zeros(self.length + self.tail)

    def add(self, sound, at_beats, pan=0.0, gain=1.0):
        start = int(at_beats * self.beat * SR)
        end = min(start + len(sound), len(self.L))
        s = sound[: end - start] * gain
        self.L[start:end] += s * np.sqrt((1 - pan) / 2)
        self.R[start:end] += s * np.sqrt((1 + pan) / 2)

    def render(self, wet=0.25, decay=2.2):
        out = []
        for ch in (self.L, self.R):
            n_ir = int(decay * SR)
            t = np.arange(n_ir) / SR
            ir = rng.normal(0, 1, n_ir) * np.exp(-t * 6.9 / decay)
            ir = lowpass(ir, 6000)
            ir /= np.sqrt(np.sum(ir ** 2))
            size = len(ch) + n_ir
            nfft = 1 << (size - 1).bit_length()
            verb = np.fft.irfft(np.fft.rfft(ch, nfft) * np.fft.rfft(ir, nfft), nfft)[:size]
            mix = np.concatenate([ch, np.zeros(n_ir)]) * (1 - wet) + verb * wet * 0.9
            # Fold everything past the loop point back onto the start, so the
            # loop is seamless: what rings out at the end rings in at the top.
            loop = mix[: self.length].copy()
            rest = mix[self.length:]
            while len(rest):
                k = min(len(rest), self.length)
                loop[:k] += rest[:k]
                rest = rest[k:]
            out.append(loop)
        stereo = np.stack(out, axis=1)
        stereo = highpass_stereo(stereo, 30)
        peak = np.max(np.abs(stereo))
        stereo = np.tanh(stereo / peak * 1.25) / np.tanh(1.25) * 0.89  # gentle limit, ~-1 dBFS
        return stereo

def highpass_stereo(x, cutoff):
    return np.stack([highpass(x[:, 0], cutoff), highpass(x[:, 1], cutoff)], axis=1)

def chord(names):
    return [hz(n) for n in names]

def save(name, stereo):
    raw = os.path.join(OUT, name + ".f32")
    stereo.astype("<f4").tofile(raw)
    m4a = os.path.join(OUT, name + ".m4a")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "2",
                    "-i", raw, "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", m4a], check=True)
    os.remove(raw)
    print(name, f"{len(stereo) / SR:.1f}s", os.path.getsize(m4a) // 1024, "KB")

# ---------- 1. Golden Hour: warm piano arpeggios ----------
def golden_hour():
    tr = Track(bars=16, bpm=76)
    prog = [["C3", "E4", "G4", "B4", "D5"], ["A2", "C4", "E4", "G4", "B4"],
            ["F2", "A3", "C4", "E4", "G4"], ["G2", "B3", "D4", "F4", "A4"]]
    for bar in range(16):
        notes = prog[bar % 4]
        b0 = bar * 4
        tr.add(piano(hz(notes[0]), 4.5, 0.9), b0, pan=-0.1)
        tr.add(piano(hz(notes[0]) * 2, 4.5, 0.4), b0, pan=-0.1)
        pattern = [1, 2, 3, 4, 3, 2, 3, 4]
        for i, idx in enumerate(pattern):
            v = 0.55 + 0.15 * (i % 2 == 0)
            tr.add(piano(hz(notes[idx]), 2.2, v), b0 + i * 0.5, pan=0.25 * (idx - 2.5) / 1.5)
        if bar >= 8:
            tr.add(pad(hz(notes[1]), 4 * tr.beat, 0.5, 1200), b0, pan=-0.4)
            tr.add(pad(hz(notes[2]), 4 * tr.beat, 0.5, 1200), b0, pan=0.4)
    save("Tune-GoldenHour", tr.render(wet=0.3, decay=2.6))

# ---------- 2. Quiet Roads: ambient documentary pads ----------
def quiet_roads():
    tr = Track(bars=8, bpm=60)
    prog = [["D3", "A3", "D4", "F#4", "A4"], ["B2", "F#3", "B3", "D4", "F#4"],
            ["G2", "D3", "G3", "B3", "D4"], ["A2", "E3", "A3", "C#4", "E4"]]
    for bar in range(8):
        notes = prog[(bar // 2) % 4] if bar % 2 == 0 else prog[(bar // 2) % 4]
        b0 = bar * 4
        if bar % 2 == 0:
            for j, nme in enumerate(notes):
                tr.add(pad(hz(nme), 8 * tr.beat + 1.0, 0.55, 1400), b0, pan=(j - 2) * 0.3)
        # sparse high piano motif
        motif = [(0, 4), (1.5, 3), (3, 2)] if bar % 2 == 0 else [(0.5, 3), (2, 4)]
        for at, idx in motif:
            tr.add(piano(hz(notes[idx]) * 2, 3.0, 0.35), b0 + at, pan=0.3)
    save("Tune-QuietRoads", tr.render(wet=0.45, decay=3.2))

# ---------- 3. Weekend: upbeat pop ----------
def weekend():
    tr = Track(bars=16, bpm=118)
    prog = [("C", ["C4", "E4", "G4"], "C2"), ("G", ["B3", "D4", "G4"], "G2"),
            ("A", ["C4", "E4", "A4"], "A2"), ("F", ["C4", "F4", "A4"], "F2")]
    for bar in range(16):
        _, triad, root = prog[bar % 4]
        b0 = bar * 4
        for beat in range(4):
            tr.add(kick(1.0 if beat in (0, 2) else 0.75), b0 + beat)
            if beat in (1, 3):
                tr.add(snare(0.9), b0 + beat, pan=0.05)
        for e in range(8):
            tr.add(hat(0.7 if e % 2 else 1.0, open_=(e == 7)), b0 + e * 0.5, pan=0.35)
        rf = hz(root)
        for at, mult in [(0, 1), (0.75, 1), (1.5, 2), (2, 1), (2.75, 1), (3.5, 1.5)]:
            tr.add(bass(rf * mult, 0.35, 0.9), b0 + at)
        # off-beat plucked chords
        for e in range(8):
            if e % 2 == 1:
                for k, nme in enumerate(triad):
                    tr.add(pluck(hz(nme), 0.4, 0.45), b0 + e * 0.5, pan=-0.3 + 0.3 * k)
        if bar >= 8:
            lead = [triad[2], triad[1], triad[2], triad[0]]
            for i, nme in enumerate(lead):
                tr.add(pluck(hz(nme) * 2, 0.6, 0.4, damp=0.998), b0 + i, pan=0.2)
    save("Tune-Weekend", tr.render(wet=0.15, decay=1.4))

# ---------- 4. Cinematic Rise: strings and timpani ----------
def cinematic():
    tr = Track(bars=8, bpm=84)
    prog = [["A2", "E3", "A3", "C4", "E4"], ["F2", "C3", "F3", "A3", "C4"],
            ["C3", "G3", "C4", "E4", "G4"], ["G2", "D3", "G3", "B3", "D4"]]
    for bar in range(8):
        notes = prog[bar % 4]
        b0 = bar * 4
        for j, nme in enumerate(notes):
            tr.add(strings(hz(nme), 4 * tr.beat + 0.6, 0.8 if bar >= 4 else 0.55), b0, pan=(j - 2) * 0.25)
        tr.add(timpani(hz(notes[0]), 0.9), b0)
        if bar >= 4:
            tr.add(timpani(hz(notes[0]), 0.5), b0 + 2.5)
            tr.add(timpani(hz(notes[0]), 0.6), b0 + 3)
            for i in range(8):
                tr.add(strings(hz(notes[3 + (i % 2)]) * 2, 0.5 * tr.beat, 0.45), b0 + i * 0.5, pan=0.3)
    save("Tune-CinematicRise", tr.render(wet=0.35, decay=3.0))

# ---------- 5. Lo-fi Nights: mellow beat and Rhodes ----------
def lofi():
    tr = Track(bars=8, bpm=82)
    prog = [["D3", "F3", "A3", "C4", "E4"], ["G2", "F3", "A3", "B3", "E4"],
            ["C3", "E3", "G3", "B3", "D4"], ["A2", "E3", "G3", "C4", "E4"]]
    swing = 0.08
    for bar in range(8):
        notes = prog[bar % 4]
        b0 = bar * 4
        tr.add(kick(0.85), b0)
        tr.add(kick(0.6), b0 + 1.5 + swing)
        tr.add(kick(0.8), b0 + 2.5)
        tr.add(snare(0.6), b0 + 1)
        tr.add(snare(0.6), b0 + 3)
        for e in range(8):
            tr.add(hat(0.45 if e % 2 else 0.6), b0 + e * 0.5 + (swing if e % 2 else 0), pan=0.3)
        for k, nme in enumerate(notes[1:]):
            tr.add(rhodes(hz(nme), 3.2, 0.7), b0 + 0.02 * k, pan=-0.2 + 0.13 * k)
        tr.add(bass(hz(notes[0]), 1.6, 0.7), b0)
        tr.add(bass(hz(notes[0]) * 1.5, 0.7, 0.5), b0 + 2.5 + swing)
    stereo = tr.render(wet=0.2, decay=1.8)
    # vinyl crackle and a softened top end
    crackle = (rng.random(len(stereo)) > 0.9993) * rng.uniform(-0.25, 0.25, len(stereo))
    hiss = rng.normal(0, 0.004, len(stereo))
    for c in range(2):
        stereo[:, c] = lowpass(stereo[:, c], 7000) + crackle + hiss
    stereo *= 0.89 / np.max(np.abs(stereo))
    save("Tune-LofiNights", stereo)

golden_hour()
quiet_roads()
weekend()
cinematic()
lofi()
