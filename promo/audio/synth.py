"""Score + sound design for the Nearclip promo, synthesised from scratch (no samples).

    .venv/bin/python audio/synth.py out/events-ko.json out/audio-ko.wav

Music: 120 BPM in F major, one chord per bar. A filtered intro under the hook (Bb, C), a bouncy groove for the three
demos (F, C/E, Dm, Bb with Rhodes-style electric piano, a round sub bass, claps, shaker and little marimba answers),
a lift for the four-platform grid (Gm7, Am7, Bbmaj7 -> C with a sixteenth-note pluck arpeggio and a snare build), the
drop on the feature cards (four on the floor, offbeat bass, stabs and a pluck lead hook: F, Am, Bb, C) and the tonic
lands on the app icon. The bar map is shared with the stage (window.MUSIC).
SFX: every UI event recorded by the stage (clicks, key taps, touches, clips flying and landing, toasts, locks).
"""
import json
import sys

import numpy as np
from scipy import signal

SR = 48000
rng = np.random.default_rng(11)


# ----------------------------------------------------------------------------- basics
def n_of(sec):
    return int(round(sec * SR))


def tt(sec):
    return np.arange(n_of(sec)) / SR


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def noise(sec):
    return rng.standard_normal(n_of(sec))


def expdec(sec, tau):
    return np.exp(-tt(sec) / tau)


def fade(x, a=0.002, r=0.01):
    x = x.copy()
    na, nr = max(1, n_of(a)), max(1, n_of(r))
    if x.ndim == 1:
        x[:na] *= np.linspace(0, 1, na)
        x[-nr:] *= np.linspace(1, 0, nr)
    else:
        x[:, :na] *= np.linspace(0, 1, na)
        x[:, -nr:] *= np.linspace(1, 0, nr)
    return x


def butter(x, kind, f, order=2):
    sos = signal.butter(order, f, kind, fs=SR, output="sos")
    return signal.sosfilt(sos, x, axis=-1)


def shelf(x, f0, gain_db, kind="low", s=1.0):
    """RBJ shelving EQ."""
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / SR
    alpha = np.sin(w0) / 2 * np.sqrt((A + 1 / A) * (1 / s - 1) + 2)
    cw, sq = np.cos(w0), 2 * np.sqrt(A) * alpha
    if kind == "low":
        b = [A * ((A + 1) - (A - 1) * cw + sq), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - sq)]
        a = [(A + 1) + (A - 1) * cw + sq, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - sq]
    else:
        b = [A * ((A + 1) + (A - 1) * cw + sq), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - sq)]
        a = [(A + 1) - (A - 1) * cw + sq, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sq]
    return signal.lfilter(np.array(b) / a[0], np.array(a) / a[0], x, axis=-1)


def sweep(x, f0, f1, q=1.2, kind="bandpass", curve="exp", block=64):
    """Time-varying RBJ biquad (cutoff glides from f0 to f1 across x)."""
    out = np.zeros_like(x)
    zi = np.zeros(2)
    blocks = int(np.ceil(len(x) / block))
    for b in range(blocks):
        u = b / max(1, blocks - 1)
        f = f0 * (f1 / f0) ** u if curve == "exp" else f0 + (f1 - f0) * u
        f = min(f, SR * 0.45)
        w = 2 * np.pi * f / SR
        alpha = np.sin(w) / (2 * q)
        cw = np.cos(w)
        if kind == "bandpass":
            bb = [alpha, 0, -alpha]
        elif kind == "lowpass":
            bb = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        else:
            bb = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        aa = [1 + alpha, -2 * cw, 1 - alpha]
        bb = np.array(bb) / aa[0]
        aa = np.array(aa) / aa[0]
        seg = x[b * block:(b + 1) * block]
        y, zi = signal.lfilter(bb, aa, seg, zi=zi)
        out[b * block:(b + 1) * block] = y
    return out


def peak_eq(x, f0, gain_db, q=0.8):
    """RBJ peaking EQ."""
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / SR
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    b = np.array([1 + alpha * A, -2 * cw, 1 - alpha * A])
    a = np.array([1 + alpha / A, -2 * cw, 1 - alpha / A])
    return signal.lfilter(b / a[0], a / a[0], x, axis=-1)


def pan2(x, pan=0.0):
    a = (pan + 1) * np.pi / 4
    return np.vstack([x * np.cos(a), x * np.sin(a)])


def pan_glide(x, p0, p1):
    p = np.linspace(p0, p1, len(x))
    a = (p + 1) * np.pi / 4
    return np.vstack([x * np.cos(a), x * np.sin(a)])


class Bus:
    def __init__(self, sec):
        self.x = np.zeros((2, n_of(sec)))

    def add(self, sound, t, gain=1.0, pan=0.0):
        s = sound if sound.ndim == 2 else pan2(sound, pan)
        i = n_of(t)
        if i < 0:
            s = s[:, -i:]
            i = 0
        j = min(self.x.shape[1], i + s.shape[1])
        if j > i:
            self.x[:, i:j] += s[:, : j - i] * gain


def reverb_ir(sec=2.4, predelay=0.02, damp=6000, seed=5):
    r = np.random.default_rng(seed)
    n = n_of(sec)
    t = np.arange(n) / SR
    env = np.exp(-t / (sec / 6.2))
    ir = np.zeros((2, n + n_of(predelay)))
    for c in range(2):
        tail = r.standard_normal(n) * env
        tail = butter(tail, "lowpass", damp, 1)
        ir[c, n_of(predelay):] = tail
    ir /= np.sqrt((ir ** 2).sum(axis=1, keepdims=True))
    return ir


def convolve(bus, ir):
    out = np.zeros((2, bus.shape[1] + ir.shape[1] - 1))
    for c in range(2):
        out[c] = signal.fftconvolve(bus[c], ir[c])
    return out[:, : bus.shape[1]]


def pingpong(x, delay, feedback=0.35, taps=6, damp=4500):
    out = np.zeros_like(x)
    d = n_of(delay)
    for k in range(1, taps + 1):
        g = feedback ** k
        src = butter(x[(k + 1) % 2], "lowpass", damp, 1)
        if k * d < x.shape[1]:
            out[k % 2, k * d:] += src[: x.shape[1] - k * d] * g
    return out


# ----------------------------------------------------------------------------- oscillators
def saw(freq, n, phase=0.0):
    """Band-limited sawtooth (polyBLEP)."""
    dt = freq / SR
    t = (phase + dt * np.arange(n)) % 1.0
    y = 2.0 * t - 1.0
    m = t < dt
    x = t[m] / dt
    y[m] -= x + x - x * x - 1.0
    m = t > 1.0 - dt
    x = (t[m] - 1.0) / dt
    y[m] -= x * x + x + x + 1.0
    return y


def pulse(freq, n, phase=0.0):
    return 0.5 * (saw(freq, n, phase) - saw(freq, n, phase + 0.5))


def env_adsr(n, a, d, s, r):
    t = np.arange(n) / SR
    e = np.where(t < a, t / max(a, 1e-6), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-6)))
    nr = min(n, n_of(r))
    e[n - nr:] *= np.linspace(1, 0, nr) ** 1.4
    return e


# ----------------------------------------------------------------------------- instruments
_cache = {}


def epiano(m, sec, vel=1.0, bright=1.0):
    """Rhodes-style FM tine: a sine carrier with a decaying 1:1 modulator, a short tine 'tick' and tremolo."""
    key = ("ep", m, round(sec, 3), round(vel, 3), round(bright, 2))
    if key in _cache:
        return _cache[key]
    f = midi(m)
    t = tt(sec + 0.3)
    idx = 1.5 * bright * np.exp(-t / 0.3) + 0.22
    y = np.sin(2 * np.pi * f * t + np.sin(2 * np.pi * f * t) * idx)
    y += 0.18 * bright * np.sin(2 * np.pi * f * 7.0 * t) * np.exp(-t / 0.014)
    env = np.minimum(1, t / 0.0015) * np.exp(-t / 1.25)
    ns = n_of(sec)
    rel = np.ones_like(t)
    rel[ns:] = np.exp(-(t[ns:] - sec) / 0.07)
    y = y * env * rel * (1 + 0.06 * np.sin(2 * np.pi * 4.8 * t))
    out = fade(y * vel * 0.1, 0.0005, 0.03)
    _cache[key] = out
    return out


def ep_chord(notes, sec, vel=1.0, bright=1.0):
    n = n_of(sec + 0.3)
    out = np.zeros((2, n))
    for k, m in enumerate(notes):
        p = -0.4 + 0.8 * k / max(1, len(notes) - 1)
        y = epiano(m, sec, vel * (1.0 if k == len(notes) - 1 else 0.82), bright)
        out += pan2(y, p)[:, :n]
    return out


def supersaw(notes, sec, cutoff=3600, detune=(-15, -6, 0, 6, 15), gain=0.05, key=None):
    if key is not None and key in _cache:
        return _cache[key]
    n = n_of(sec)
    st = np.zeros((2, n))
    r = np.random.default_rng(abs(hash(tuple(notes))) % 2 ** 32)
    for m in notes:
        f = midi(m)
        for k, c in enumerate(detune):
            y = saw(f * 2 ** (c / 1200), n, r.random())
            p = 0.8 * (k / (len(detune) - 1) * 2 - 1)
            a = (p + 1) * np.pi / 4
            st[0] += y * np.cos(a)
            st[1] += y * np.sin(a)
    st = butter(st, "lowpass", cutoff, 2) * gain / len(detune)
    st = butter(st, "highpass", 200, 1)
    if key is not None:
        _cache[key] = st
    return st


def stab(notes, sec=0.2, cutoff=3800, vel=1.0):
    base = supersaw(notes, sec + 0.06, cutoff, key=("stab", tuple(notes), cutoff, round(sec, 3)))
    e = env_adsr(base.shape[1], 0.003, 0.08, 0.25, 0.06)
    return base * e * vel


def pad(notes, sec, cutoff=1800, attack=0.4, release=0.6, vel=1.0):
    st = supersaw(notes, sec, cutoff, detune=(-10, -4, 4, 10), gain=0.05)
    e = env_adsr(st.shape[1], attack, 10.0, 1.0, release)
    return st * e * vel


def bass_note(m, sec, vel=1.0, bright=700):
    n = n_of(sec)
    t = np.arange(n) / SR
    f = midi(m)
    sub = np.sin(2 * np.pi * f * t)
    mid = butter(saw(f, n) + 0.35 * saw(f * 1.004, n, 0.3), "lowpass", bright, 2)
    e = np.minimum(1, t / 0.004) * np.exp(-t / max(sec * 0.6, 0.05))
    y = (sub * 0.9 + mid * 0.45) * e
    y = np.tanh(y * 1.6) / 1.6
    return fade(y * vel * 0.36, 0.001, 0.015)


def pluck(m, sec=0.6, bright=1.0, vel=1.0):
    f = midi(m)
    t = tt(sec)
    y = np.zeros_like(t)
    for k in range(1, 16):
        if f * k > 14000:
            break
        decay = 0.38 / (1 + 0.6 * (k - 1) / bright)
        y += (1 / k) * np.exp(-t / decay) * np.sin(2 * np.pi * f * k * t + 0.3 * k)
    y *= np.exp(-t / 0.45)
    return fade(y * vel * 0.3, 0.001, 0.05)


def lead(m, sec, vel=1.0):
    """Bright pluck lead: two detuned pulses through a closing low-pass, plus a bell partial."""
    n = n_of(sec + 0.15)
    f = midi(m)
    y = pulse(f, n) * 0.6 + pulse(f * 2 ** (7 / 1200), n, 0.31) * 0.5 + saw(f * 2, n) * 0.12
    y = sweep(y, 6400, 1200, q=0.9, kind="lowpass", block=96)
    e = env_adsr(n, 0.003, 0.14, 0.38, 0.1)
    t = np.arange(n) / SR
    bellp = np.sin(2 * np.pi * f * 3 * t) * np.exp(-t / 0.09) * 0.18
    return fade((y * e + bellp) * vel * 0.12, 0.001, 0.04)


def mallet(m, vel=1.0):
    t = tt(0.5)
    f = midi(m)
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.18) + 0.3 * np.sin(2 * np.pi * f * 4 * t) * np.exp(-t / 0.04)
    y += 0.1 * np.sin(2 * np.pi * f * 9.2 * t) * np.exp(-t / 0.01)
    return fade(y * vel * 0.15, 0.0008, 0.05)


def bell(m, sec=2.5, vel=1.0):
    f = midi(m)
    t = tt(sec)
    index = 2.0 * np.exp(-t / 0.25)
    y = np.sin(2 * np.pi * f * t + np.sin(2 * np.pi * f * 3.5 * t) * index) * np.exp(-t / 0.9)
    y += 0.25 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t / 0.35)
    return fade(y * vel * 0.25, 0.001, 0.2)


# drums
def kick(vel=1.0, tight=False):
    t = tt(0.4)
    f = 48 + 120 * np.exp(-t / 0.028) + 24 * np.exp(-t / 0.1)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (0.16 if tight else 0.24))
    body = np.tanh(body * 2.2) / np.tanh(2.2)
    click = butter(noise(0.4), "bandpass", [1800, 7000]) * np.exp(-t / 0.003) * 0.28
    return fade((body * 0.92 + click) * vel * 0.6, 0.0004, 0.02)


def clap(vel=1.0):
    sec = 0.32
    y = np.zeros(n_of(sec))
    for k, off in enumerate((0, 0.009, 0.019, 0.028)):
        burst = noise(0.25) * expdec(0.25, 0.006 if k < 3 else 0.07)
        i = n_of(off)
        y[i:i + len(burst)] += burst[: len(y) - i]
    y = butter(y, "bandpass", [1000, 5600])
    t = tt(sec)
    body = np.sin(2 * np.pi * 200 * t) * np.exp(-t / 0.03) * 0.22
    return fade((y * 0.19 + body * 0.45) * vel, 0.0004, 0.03)


def snare(vel=1.0):
    t = tt(0.2)
    body = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.045) * 0.42
    sn = butter(noise(0.2), "bandpass", [1600, 8500]) * np.exp(-t / 0.06)
    return fade((body + sn) * vel * 0.16, 0.0004, 0.02)


def hat(vel=1.0, sec=0.04):
    y = butter(noise(sec + 0.02), "highpass", 7800, 2) * expdec(sec + 0.02, sec / 3.2)
    return fade(y * vel * 0.08, 0.0004, 0.008)


def open_hat(vel=1.0, sec=0.22):
    y = butter(noise(sec), "highpass", 7000, 2) * expdec(sec, 0.07)
    return fade(y * vel * 0.06, 0.0006, 0.03)


def shaker(vel=1.0):
    sec = 0.08
    t = tt(sec)
    y = butter(noise(sec), "bandpass", [5200, 12000]) * np.minimum(1, t / 0.01) * np.exp(-t / 0.022)
    return fade(y * vel * 0.07, 0.001, 0.01)


def crash(vel=1.0, sec=2.4):
    t = tt(sec)
    x = butter(noise(sec), "highpass", 4200, 2) * np.exp(-t / 0.6)
    metal = np.zeros_like(t)
    for f in (3810, 5230, 6650, 7420, 8890, 10350):
        metal += np.sin(2 * np.pi * f * t + rng.random() * 6.28)
    metal *= np.exp(-t / 0.42) * 0.02
    y = x * 0.09 + metal * 0.7
    st = np.vstack([y, butter(np.roll(y, 41), "highpass", 4600, 1)])
    return fade(st * vel, 0.0004, 0.4)


def rev_crash(sec=1.2):
    c = crash(1.0, sec)[:, ::-1]
    e = np.linspace(0, 1, c.shape[1]) ** 2.2
    return fade(c * e * 0.85, 0.05, 0.004)


# ----------------------------------------------------------------------------- sfx
def sfx_click(bright=1.0):
    t = tt(0.06)
    y = butter(noise(0.06), "highpass", 2800) * np.exp(-t / 0.0025) * 0.7
    y += np.sin(2 * np.pi * 2300 * bright * t) * np.exp(-t / 0.008) * 0.35
    y += np.sin(2 * np.pi * 160 * t) * np.exp(-t / 0.012) * 0.4
    return fade(y * 0.4, 0.0003, 0.01)


def sfx_key(big=False):
    t = tt(0.12)
    body = np.sin(2 * np.pi * (150 + 60 * np.exp(-t / 0.01)) * t) * np.exp(-t / 0.03)
    top = butter(noise(0.12), "bandpass", [1400, 5200]) * np.exp(-t / 0.006)
    tick = butter(noise(0.12), "highpass", 5000) * np.exp(-t / 0.0015)
    y = body * 0.55 + top * 0.6 + tick * 0.35
    return fade(y * (0.52 if big else 0.42), 0.0003, 0.02)


def sfx_tick(pitch=0.0, gain=0.15):
    f = 2050 * 2 ** pitch
    t = tt(0.05)
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.009) + 0.3 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t / 0.004)
    return fade(y * gain, 0.0003, 0.01)


def sfx_tap(long=False):
    """A finger on glass: a soft low thump with a short, damped click."""
    t = tt(0.14)
    thump = np.sin(2 * np.pi * (110 + 90 * np.exp(-t / 0.01)) * t) * np.exp(-t / 0.035) * 0.5
    click = butter(noise(0.14), "bandpass", [900, 3600]) * np.exp(-t / 0.004) * 0.3
    y = thump + click
    if long:  # the long press ends in a haptic tick
        y = y * 0.8
    return fade(y * 0.42, 0.0004, 0.02)


def sfx_haptic():
    t = tt(0.06)
    y = np.sin(2 * np.pi * 170 * t) * np.exp(-t / 0.012)
    return fade(y * 0.3, 0.0004, 0.01)


def sfx_whoosh(sec=0.42, f0=350, f1=3200, gain=0.35, q=0.9):
    y = sweep(noise(sec), f0, f1, q=q)
    env = np.sin(np.pi * np.linspace(0, 1, len(y))) ** 1.6
    return fade(y * env * gain, 0.002, 0.02)


def sfx_open():
    w = sfx_whoosh(0.2, 500, 2400, 0.18, 1.1)
    t = tt(0.2)
    glide = np.sin(2 * np.pi * np.cumsum(420 + 380 * (t / 0.2)) / SR) * np.exp(-t / 0.06) * 0.07
    return w + glide


def sfx_pop(f0=520, f1=1050, sec=0.08, gain=0.22):
    t = tt(sec)
    f = f0 + (f1 - f0) * (1 - np.exp(-t / (sec / 3)))
    y = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (sec / 3.5))
    return fade(y * gain, 0.0005, 0.01)


def sfx_done():
    a, b = bell(88, 1.2, 0.9), bell(95, 1.2, 0.8)
    out = np.zeros(n_of(1.4))
    out[: len(a)] += a
    out[n_of(0.075): n_of(0.075) + len(b)] += b
    return out * 0.85


def sfx_riser(sec, top=7000):
    t = tt(sec)
    x = sweep(noise(sec), 300, top, q=2.0)
    env = (t / sec) ** 2.2
    tone = np.zeros_like(t)
    for k, base in enumerate((116.5, 174.6, 233.1)):
        f = base * 2 ** (2.0 * (t / sec) ** 1.6)
        tone += np.sin(2 * np.pi * np.cumsum(f) / SR + k)
    return fade((x * 0.5 + tone * 0.05) * env * 0.4, 0.01, 0.01)


def sfx_whoosh_big(f0=180, f1=9000, sec=0.6):
    x = sweep(noise(sec), f0, f1, q=0.8)
    env = np.sin(np.pi * np.linspace(0, 1, len(x))) ** 1.2
    t = tt(sec)
    drop = np.sin(2 * np.pi * np.cumsum(140 * np.exp(-t / 0.25) + 35) / SR) * env * 0.22
    st = np.vstack([x * env * np.linspace(1.0, 0.25, len(x)), x * env * np.linspace(0.25, 1.0, len(x))]) * 0.5
    return st + pan2(drop, 0)


def sfx_impact(scale=1.0):
    t = tt(2.2)
    boom = np.sin(2 * np.pi * np.cumsum(36 + 46 * np.exp(-t / 0.08)) / SR) * np.exp(-t / 0.75) * 0.8
    boom = np.tanh(boom * 1.8) / 1.8
    crack = butter(noise(2.2), "lowpass", 3200) * np.exp(-t / 0.05) * 0.35
    return fade((boom + crack) * scale, 0.0005, 0.2)


def sfx_chime(notes=(84, 88, 91)):
    out = np.zeros(n_of(2.6))
    for k, (m, d) in enumerate(zip(notes, (0.0, 0.055, 0.11))):
        b = bell(m, 2.4, 0.55 - 0.1 * k)
        i = n_of(d)
        out[i:i + len(b)] += b[: len(out) - i]
    return out


def sfx_receive(i=0):
    """A clip arriving: two quick bell notes, a step higher for each device in a ripple."""
    base = (84, 86, 88, 91)[i % 4]
    out = np.zeros(n_of(1.6))
    for k, (m, d) in enumerate(((base, 0.0), (base + 7, 0.06))):
        b = bell(m, 1.4, 0.5 - 0.12 * k)
        j = n_of(d)
        out[j:j + len(b)] += b[: len(out) - j]
    return out


def sfx_ping(i=0):
    t = tt(0.9)
    f = 1396.9 * (1.0, 1.122, 1.26)[i % 3]
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.16) + 0.2 * np.sin(2 * np.pi * f * 2.01 * t) * np.exp(-t / 0.06)
    return fade(y * 0.09, 0.002, 0.1)


def sfx_mosaic(n=7, gap=0.045):
    out = np.zeros(n_of(gap * n + 0.05))
    for k in range(n):
        b = butter(noise(0.03), "bandpass", [1600 + 260 * k, 4200 + 380 * k]) * expdec(0.03, 0.005) * 0.11
        i = n_of(gap * k)
        out[i:i + len(b)] += b
    return out


def sfx_lock(up=False):
    t = tt(0.16)
    a = butter(noise(0.16), "highpass", 3000) * np.exp(-t / 0.004) * 0.4
    f1, f2 = (1850, 620) if not up else (2300, 880)
    a += np.sin(2 * np.pi * f1 * t) * np.exp(-t / 0.02) * 0.2 + np.sin(2 * np.pi * f2 * t) * np.exp(-t / 0.03) * 0.25
    return fade(a * 0.5, 0.0003, 0.01)


def sfx_snap():
    out = np.zeros(n_of(0.12))
    for d, g in ((0.0, 1.0), (0.035, 0.7)):
        t = tt(0.05)
        y = butter(noise(0.05), "highpass", 2500) * np.exp(-t / 0.002) * 0.5 + np.sin(2 * np.pi * 1300 * t) * np.exp(-t / 0.01) * 0.25
        i = n_of(d)
        out[i:i + len(y)] += y * g
    return out * 0.6


def sfx_scramble(sec=0.8, seed=3):
    r = np.random.default_rng(seed)
    out = np.zeros(n_of(sec + 0.05))
    k, t0 = 0, 0.0
    while t0 < sec:
        f = 900 + 2600 * r.random()
        d = 0.012 + 0.02 * r.random()
        t = tt(d)
        y = np.sign(np.sin(2 * np.pi * f * t)) * np.exp(-t / (d / 2.5)) * 0.04
        y = butter(y, "lowpass", 6000, 1)
        i = n_of(t0)
        out[i:i + len(y)] += y * (0.6 + 0.4 * r.random())
        t0 += 0.03 + 0.03 * r.random()
        k += 1
    env = np.sin(np.pi * np.linspace(0, 1, len(out))) ** 0.6
    return out * env


# ----------------------------------------------------------------------------- score
CH = {
    "Bb": ([50, 53, 57, 62], 34),
    "Csus": ([53, 55, 60, 65], 36),
    "C": ([52, 55, 60, 64], 36),
    "F": ([53, 57, 60, 64], 41),
    "C/E": ([52, 55, 60, 67], 40),
    "Dm": ([50, 57, 60, 65], 38),
    "Gm7": ([50, 53, 58, 62], 43),
    "Am7": ([52, 55, 60, 64], 45),
    "Bbmaj7": ([53, 57, 62, 65], 34),
    "Am": ([52, 57, 60, 64], 45),
}
PROG = {0: "Bb", 1: "Csus", 2: "F", 3: "C/E", 4: "Dm", 5: "Bb", 6: "F", 7: "C/E", 8: "Dm", 9: "Bb",
        10: "Gm7", 11: "Am7", 12: "Bbmaj7", 13: "F", 14: "Am", 15: "Bb", 16: "C", 17: "F", 18: "F"}


def chord_at(bar, step):
    if bar == 12 and step >= 8:
        return "C"
    if bar == 1 and step >= 8:
        return "C"
    return PROG.get(bar, "F")


# lead hook on the feature cards: (bar, 16th step, midi, length in 16ths)
LEAD = [
    (13, 0, 72, 2), (13, 2, 77, 2), (13, 4, 76, 2), (13, 6, 72, 2), (13, 8, 69, 3), (13, 11, 72, 3), (13, 14, 74, 2),
    (14, 0, 76, 3), (14, 3, 72, 3), (14, 6, 69, 2), (14, 8, 76, 3), (14, 11, 79, 3), (14, 14, 77, 2),
    (15, 0, 77, 3), (15, 3, 74, 3), (15, 6, 70, 2), (15, 8, 74, 3), (15, 11, 77, 3), (15, 14, 81, 2),
    (16, 0, 79, 4), (16, 4, 76, 2), (16, 6, 79, 2), (16, 8, 84, 6), (16, 14, 81, 2),
    (17, 0, 77, 14),
]
# marimba answers during the demos: (bar, step, midi)
ANSWERS = [(3, 10, 79), (3, 12, 76), (3, 14, 72), (5, 10, 77), (5, 12, 74), (5, 14, 70),
           (7, 10, 79), (7, 12, 76), (7, 14, 72), (9, 10, 81), (9, 12, 77), (9, 14, 74)]
# pluck arpeggio for the four-platform grid (chord tones up two octaves, 16ths)
ARP = {"Gm7": [67, 70, 74, 77], "Am7": [69, 72, 76, 79], "Bbmaj7": [70, 74, 77, 81], "C": [72, 76, 79, 84]}


def build(events, duration, music, parts=False):
    bpm = music.get("bpm", 120)
    beat = 60 / bpm
    bar_len = 4 * beat
    s16 = beat / 4
    at = lambda bar, step=0: bar * bar_len + step * s16
    total = duration + 3
    music_bus, verb, delay, sfx, sfx_verb = Bus(total), Bus(total), Bus(total), Bus(total), Bus(total)
    duck_src = Bus(total)
    kicks = []
    BARS = 19

    def section(bar):
        if bar < 2:
            return "intro"
        if bar < 10:
            return "A"
        if bar < 13:
            return "B"
        if bar < 17:
            return "C"
        if bar < 18:
            return "F"
        return "end"

    for bar in range(0, BARS):
        sec = section(bar)
        for step in range(16):
            t = at(bar, step)
            ch = chord_at(bar, step)
            notes, root = CH[ch]
            b4 = step % 4
            # ---- kick
            kick_on = False
            if sec == "intro":
                kick_on = (bar == 0 and step == 0) or (bar == 1 and step in (0, 8))
            elif sec == "A":
                kick_on = step in (0, 6, 8) or (step == 14 and bar % 2 == 1)
            elif sec == "B":
                kick_on = step in (0, 6, 8, 11) if bar < 12 else step in (0, 4, 8)
            elif sec == "C":
                kick_on = b4 == 0
            elif sec == "F":
                kick_on = step in (0, 8)
            elif sec == "end":
                kick_on = step == 0
            if kick_on:
                v = {"intro": 0.7, "A": 0.85, "B": 0.9, "C": 0.98, "F": 0.9, "end": 0.95}[sec]
                music_bus.add(kick(v, tight=sec in ("A", "B")), t, 1.0)
                kicks.append(t)
            # ---- clap / snare on 2 and 4
            if step in (4, 12) and sec in ("A", "B", "C", "F") and not (sec == "B" and bar == 12 and step == 12):
                c = clap(0.95 if sec != "A" else 0.85)
                music_bus.add(c, t, 1.0, pan=0.03)
                verb.add(pan2(c, 0), t, 0.28)
                if sec in ("C", "F"):
                    music_bus.add(snare(0.65), t, 1.0)
            if sec == "intro" and bar == 1 and step in (4, 12):
                music_bus.add(clap(0.6), t, 1.0)
            # ---- hats and shaker
            if sec in ("A", "B", "C", "F"):
                if b4 == 2:
                    if sec in ("B", "C"):
                        music_bus.add(open_hat(0.85 if sec == "C" else 0.6), t, 1.0, pan=-0.2)
                    else:
                        music_bus.add(hat(0.8), t, 1.0, pan=0.25)
                elif b4 == 0:
                    music_bus.add(hat(0.4), t, 1.0, pan=0.25)
                if sec in ("A", "B", "C"):
                    music_bus.add(shaker(0.9 if b4 == 2 else 0.55), t, 1.0, pan=-0.35)
                if sec == "C" and b4 in (1, 3):
                    music_bus.add(hat(0.32), t, 1.0, pan=0.3)
            elif sec == "intro" and b4 == 2:
                music_bus.add(hat(0.45 if bar == 0 else 0.7), t, 1.0, pan=0.25)
            # ---- bass
            if sec == "A":
                if step == 0:
                    duck_src.add(pan2(bass_note(root, beat * 1.4, 0.95, 650), 0), t, 1.0)
                elif step in (6, 10):
                    duck_src.add(pan2(bass_note(root + (12 if step == 10 else 0), beat * 0.45, 0.75, 800), 0), t, 1.0)
                elif step == 14:
                    duck_src.add(pan2(bass_note(root + 7, s16 * 1.6, 0.55, 900), 0), t, 1.0)
            elif sec == "B":
                if step in (0, 6, 10, 14):
                    duck_src.add(pan2(bass_note(root + (12 if step == 14 else 0), beat * (1.2 if step == 0 else 0.5), 0.85, 750), 0), t, 1.0)
            elif sec == "C":
                if b4 == 2:
                    duck_src.add(pan2(bass_note(root + 12, beat * 0.42, 0.95, 1000), 0), t, 1.0)
                if step == 0:
                    duck_src.add(pan2(bass_note(root, beat * 1.5, 0.35, 300), 0), t, 1.0)
            elif sec == "F" and step == 0:
                duck_src.add(pan2(bass_note(root, beat * 3.5, 0.9, 500), 0), t, 1.0)
            # ---- electric piano comping
            if sec in ("intro", "A", "B") and step in (0, 6, 10, 14):
                if sec == "intro":
                    vel, length, br = (0.7 if bar == 0 else 0.85), (beat * 1.4 if step == 0 else beat * 0.4), 0.6 + 0.4 * bar
                else:
                    vel, length, br = (1.0 if step == 0 else 0.72), (beat * 1.4 if step == 0 else beat * 0.42), 1.0
                e = ep_chord(notes, length, vel, br)
                duck_src.add(e, t, 0.95)
                verb.add(e, t, 0.18)
            # ---- stabs on the cards
            if sec == "C" and step in (0, 3, 6, 10, 12):
                s = stab(notes, 0.19, 4400, (1.0, 0.75, 0.88, 0.82, 0.7)[(0, 3, 6, 10, 12).index(step)])
                duck_src.add(s, t, 1.0)
                delay.add(s, t, 0.1)
            # ---- pluck arpeggio on the grid
            if sec == "B" and not (bar == 12 and step >= 12):
                arp = ARP.get(ch)
                if arp:
                    m = arp[[0, 1, 2, 3, 2, 1, 2, 3][step % 8]]
                    p = pluck(m, 0.3, 1.4, 0.32 + 0.12 * (bar - 10) / 2)
                    music_bus.add(p, t, 1.0, pan=0.3 if step % 2 else -0.3)
                    delay.add(pan2(p, 0), t, 0.25)

    # pads under the grid, the cards and the end
    for bar in range(10, BARS):
        sec = section(bar)
        for half in (0, 8):
            ch = chord_at(bar, half)
            notes, _ = CH[ch]
            v = {"B": 0.55, "C": 0.85, "F": 0.0, "end": 0.0}.get(sec, 0)
            if v:
                p = pad([n - 12 for n in notes] + [notes[-1]], 2 * beat + 0.12, cutoff=2400 if sec == "B" else 3200, attack=0.04, release=0.12, vel=v)
                duck_src.add(p, at(bar, half), 1.0)

    # marimba answers in the demos
    for bar, step, m in ANSWERS:
        s = mallet(m, 0.85)
        music_bus.add(s, at(bar, step), 0.85, pan=0.28 if step != 12 else -0.28)
        delay.add(pan2(s, 0), at(bar, step), 0.3)
        verb.add(pan2(s, 0), at(bar, step), 0.22)

    # lead hook
    for bar, step, m, length in LEAD:
        t = at(bar, step)
        s = lead(m, length * s16, 1.0 if bar < 17 else 1.05)
        music_bus.add(s, t, 1.0, pan=0.0)
        delay.add(pan2(s, 0), t, 0.4)
        verb.add(pan2(s, 0), t, 0.3)

    # transitions: crashes, risers, fills
    for t, v in ((at(2), 0.75), (at(6), 0.45), (at(10), 0.8), (at(13), 1.15), (at(15), 0.55), (at(17), 1.1)):
        music_bus.add(crash(v), t, 1.0)
    music_bus.add(rev_crash(1.0), at(2) - 1.0, 0.7)
    music_bus.add(rev_crash(1.4), at(13) - 1.4, 0.95)
    music_bus.add(rev_crash(0.9), at(17) - 0.9, 0.8)
    music_bus.add(pan2(sfx_riser(at(2) - at(1, 4), 6000), 0), at(1, 4), 0.55)
    music_bus.add(pan2(sfx_riser(at(13) - at(12), 9000), 0), at(12), 0.95)
    for i in range(4):
        music_bus.add(snare(0.3 + 0.12 * i), at(1, 12 + i), 0.9)
    for i in range(4):
        music_bus.add(snare(0.28 + 0.1 * i), at(9, 12 + i), 0.85)
    t, gap = at(12, 8), s16 * 2
    while t < at(13) - s16 * 0.4:
        v = 0.3 + 0.7 * (t - at(12, 8)) / (at(13) - at(12, 8))
        sn = snare(v)
        music_bus.add(sn, t, 1.0)
        verb.add(pan2(sn, 0), t, 0.22)
        t += gap
        gap = max(s16 / 2, gap * 0.88)
    for i in range(4):
        music_bus.add(snare(0.35 + 0.1 * i), at(16, 12 + i), 0.85)

    # the icon lands (bar 17) and the end (bar 18)
    FIN, END = at(17), at(18)
    music_bus.add(pan2(sfx_impact(0.9), 0), FIN, 0.85)
    fin_pad = pad([41, 53, 57, 60, 64, 67, 72], 2.2, cutoff=4200, attack=0.01, release=1.2, vel=0.9)
    duck_src.add(fin_pad, FIN, 0.6)
    verb.add(fin_pad, FIN, 0.4)
    fe = ep_chord([57, 60, 64, 67], beat * 1.6, 0.9, 1.0)
    duck_src.add(fe, at(17, 8), 0.8)
    verb.add(fe, at(17, 8), 0.3)
    end_pad = pad([41, 48, 53, 57, 60, 64, 67, 72], 3.4, cutoff=3800, attack=0.005, release=2.4, vel=1.0)
    music_bus.add(end_pad, END, 0.85)
    verb.add(end_pad, END, 0.5)
    music_bus.add(pan2(bass_note(29, 2.4, 0.9, 450), 0), END, 1.0)
    music_bus.add(crash(0.9, 3.0), END, 1.0)
    for i, (m, d) in enumerate(((77, 0.0), (81, 0.09), (84, 0.18), (89, 0.27))):
        bl = bell(m, 2.6, 0.66 - 0.08 * i)
        music_bus.add(bl, END + d, 0.42, pan=(-0.3, 0.3)[i % 2])
        verb.add(pan2(bl, 0), END + d, 0.5)

    # sidechain pump
    duck = np.ones(duck_src.x.shape[1])
    for kt in kicks:
        i = n_of(kt)
        n = n_of(0.32)
        seg = 1 - 0.68 * np.exp(-np.arange(n) / SR / 0.08)
        j = min(len(duck), i + n)
        duck[i:j] = np.minimum(duck[i:j], seg[: j - i])
    music_bus.x += duck_src.x * duck

    # ------------------------------------------------------------------ sfx
    CHIP = [77, 81, 84, 89]
    for e in events:
        name, t = e["name"], e["t"]
        i = e.get("i", 0)
        p = e.get("pan", 0.0)
        if name == "roll":
            sfx.add(sfx_pop(560 * 2 ** (i * 2 / 12), 980 * 2 ** (i * 2 / 12), 0.07, 0.2), t, 1.0, pan=-0.15 + 0.1 * i)
            sfx.add(sfx_tick(0.25 + 0.05 * i, 0.1), t + 0.03, 1.0, pan=0.2)
        elif name == "hookout":
            sfx.add(sfx_whoosh(0.32, 700, 3600, 0.12, 1.2), t, 1.0)
        elif name == "zoomout":
            w = sfx_whoosh_big(9000, 220, 1.0)
            sfx.add(w, t - 0.05, 0.75)
            sfx_verb.add(w, t, 0.25)
        elif name == "open":
            sfx.add(sfx_open(), t - 0.01, 1.7, pan=p)
        elif name == "click":
            sfx.add(sfx_click(), t, 1.0, pan=p)
        elif name == "select":
            sfx.add(sfx_tick(-0.1, 0.18), t, 1.0, pan=p)
            sfx.add(sfx_haptic(), t, 0.6, pan=p)
        elif name == "key":
            s = sfx_key(e.get("big", False))
            sfx.add(s, t, 1.0)
            sfx_verb.add(s, t, 0.12 if e.get("big") else 0.05)
        elif name == "fly":
            w = sfx_whoosh(0.62, 500, 4200, 0.3 if not e.get("soft") else 0.26, 1.0)
            sfx.add(pan_glide(w, e.get("from", -0.4), e.get("to", 0.4)), t - 0.12, 1.0)
        elif name == "land":
            sfx.add(sfx_pop(380, 820, 0.1, 0.26), t, 1.0, pan=p)
        elif name == "receive":
            r = sfx_receive(i)
            sfx.add(r, t, 0.62, pan=p)
            sfx_verb.add(pan2(r, 0), t, 0.2)
        elif name == "wipe":
            w = sfx_whoosh_big(300, 6000, 0.55)
            sfx.add(w[::-1], t - 0.06, 0.6)
        elif name == "tap":
            sfx.add(sfx_tap(e.get("long", False)), t, 1.0, pan=p)
        elif name == "toast":
            sfx.add(pan2(sfx_whoosh(0.26, 1200, 3600, 0.12, 1.4), p), t - 0.03, 1.0)
            sfx.add(sfx_pop(700, 1100, 0.07, 0.14), t + 0.04, 1.0, pan=p)
        elif name == "digits":
            for k in range(6):
                sfx.add(sfx_tick(0.1 + 0.04 * k, 0.16), t + 0.035 * k, 1.0, pan=p - 0.1 + 0.04 * k)
        elif name == "ok":
            d = sfx_done()
            sfx.add(d, t, 0.5, pan=p)
            sfx_verb.add(d, t, 0.12)
        elif name == "fresh":
            sfx.add(sfx_ping(0), t, 1.7, pan=p)
        elif name == "paste":
            sfx.add(sfx_whoosh(0.3, 900, 3800, 0.13, 1.1), t - 0.12, 1.0, pan=p)
            sfx.add(sfx_pop(420, 900, 0.09, 0.2), t, 1.0, pan=p)
        elif name == "pindrop":
            tt_ = tt(0.18)
            thud = np.sin(2 * np.pi * (95 + 120 * np.exp(-tt_ / 0.02)) * tt_) * np.exp(-tt_ / 0.05) * 0.32
            sfx.add(fade(thud, 0.0005, 0.02), t + 0.12, 1.0, pan=p)
            sfx.add(sfx_pop(330, 760, 0.1, 0.24), t + 0.1, 1.0, pan=p)
        elif name == "bubble":
            sfx.add(sfx_whoosh(0.22, 1000, 3200, 0.1, 1.2), t - 0.08, 1.0, pan=p)
            sfx.add(sfx_pop(520, 1150, 0.09, 0.26), t, 1.0, pan=p)
        elif name == "reply":
            sfx.add(sfx_pop(820, 1300, 0.07, 0.18), t, 1.0, pan=p)
            sfx.add(sfx_ping(1), t + 0.02, 0.9, pan=p)
        elif name == "sms":
            # a text message on the phone: a buzz on the desk and a two-note tone
            sfx.add(sfx_haptic(), t - 0.02, 0.8, pan=p)
            sfx.add(sfx_ping(1), t, 1.15, pan=p)
            sfx.add(sfx_ping(2), t + 0.12, 1.0, pan=p)
        elif name == "detect":
            # Nearclip finds the code: a short bright sweep over the digits
            sfx.add(sfx_whoosh(0.24, 1800, 5600, 0.07, 1.8), t - 0.03, 1.0, pan=p)
            sfx.add(sfx_tick(0.32, 0.12), t + 0.16, 1.0, pan=p)
        elif name == "tile":
            sfx.add(sfx_whoosh(0.3, 600 * 2 ** (i * 0.12), 3400 * 2 ** (i * 0.12), 0.22, 1.2), t - 0.04, 1.0, pan=p)
        elif name == "card":
            sfx.add(sfx_whoosh(0.22, 2600, 600, 0.2, 1.0), t - 0.02, 1.0)
        elif name == "qr":
            sfx.add(sfx_mosaic(8, 0.045), t, 2.3, pan=0.25)
        elif name == "bracket":
            sfx.add(sfx_snap(), t, 1.0, pan=0.25)
        elif name == "scan":
            sfx.add(sfx_whoosh(0.3, 1500, 6000, 0.16, 2.2), t, 1.0, pan=0.25)
        elif name == "draw":
            sfx.add(sfx_whoosh(0.38, 600, 2400, 0.16, 1.4), t, 1.0, pan=-0.3)
        elif name == "pop":
            sfx.add(sfx_pop(600, 1000, 0.08, 0.28), t, 1.0, pan=p)
        elif name == "lock":
            sfx.add(sfx_lock(), t, 1.0, pan=-0.2)
        elif name == "scramble":
            sfx.add(sfx_scramble(e.get("dur", 0.8)), t, 1.8, pan=0.0)
        elif name == "unlock":
            sfx.add(sfx_lock(True), t, 1.0, pan=0.25)
        elif name == "type":
            sfx.add(sfx_key(False), t, 0.8, pan=0.3)
        elif name == "filter":
            sfx.add(sfx_whoosh(0.3, 3000, 800, 0.18, 1.2), t, 1.0, pan=0.3)
        elif name == "pin":
            sfx.add(sfx_pop(640, 1280, 0.08, 0.3), t, 1.0, pan=0.3)
        elif name == "morph":
            w = sfx_whoosh(0.42, 2800, 400, 0.32, 0.9)
            sfx.add(w, t - 0.02, 1.0)
        elif name in ("name", "tag"):
            sfx.add(sfx_whoosh(0.34, 500, 2400, 0.12, 1.2), t - 0.04, 1.0)
        elif name == "chip":
            s = pluck(CHIP[i % 4], 0.6, 1.5, 0.45)
            sfx.add(s, t, 0.6, pan=-0.3 + 0.2 * i)
            sfx_verb.add(pan2(s, 0), t, 0.25)
        elif name == "logo":
            pass  # scored with the music (bar 17)

    # ------------------------------------------------------------------ mix
    ir = reverb_ir()
    wet = convolve(verb.x, ir) + convolve(sfx_verb.x, ir) * 0.9
    dly = pingpong(delay.x, beat * 0.75, 0.34)
    music_mix = music_bus.x + dly * 0.42 + convolve(dly * 0.22, ir)
    music_mix = butter(music_mix, "highpass", 32, 2)
    music_mix = shelf(music_mix, 110, -3.5, "low", 0.8)
    music_mix = peak_eq(music_mix, 420, -2.5, 0.8)
    # make room for the UI sounds: the music dips up to 3 dB while one plays
    sfx_all = sfx.x.mean(axis=0)
    env = np.sqrt(signal.lfilter([1 - np.exp(-1 / (SR * 0.02))], [1, -np.exp(-1 / (SR * 0.02))], sfx_all ** 2) + 1e-12)
    env = signal.lfilter([1 - np.exp(-1 / (SR * 0.12))], [1, -np.exp(-1 / (SR * 0.12))], env)
    dip = 1 - 0.3 * np.clip(env / (np.percentile(env, 99) + 1e-9), 0, 1)
    music_mix *= dip
    lvl = np.sqrt(signal.lfilter([1 - np.exp(-1 / (SR * 0.03))], [1, -np.exp(-1 / (SR * 0.03))], (music_mix ** 2).mean(axis=0)) + 1e-12)
    thr = np.percentile(lvl, 70)
    gain = np.where(lvl > thr, (thr / lvl) ** 0.35, 1.0)
    music_mix *= gain
    if parts:
        m = music_mix * 0.74 + convolve(verb.x, ir) * 0.48
        return m[:, :n_of(duration)], (mix_sfx := sfx.x + convolve(sfx_verb.x, ir) * 0.9 * 0.48)[:, :n_of(duration)]
    mix = music_mix * 0.74 + wet * 0.48 + sfx.x * 1.0
    mix = shelf(mix, 7500, -2.0, "high", 0.8)

    n = n_of(duration)
    mix = mix[:, :n]
    fade_n = n_of(1.2)
    mix[:, -fade_n:] *= np.linspace(1, 0, fade_n) ** 1.8
    return mix


def master(x, target_lufs=-14.0, ceiling_db=-1.2):
    try:
        import pyloudnorm as pyln

        meter = pyln.Meter(SR)
        loud = meter.integrated_loudness(x.T)
        x = x * 10 ** ((target_lufs - loud) / 20)
    except Exception as e:  # pragma: no cover
        print("loudness skipped:", e)
        x = x / (np.abs(x).max() + 1e-9) * 0.5
    ceiling = 10 ** (ceiling_db / 20)
    over = np.abs(signal.resample_poly(x, 4, 1, axis=1)).max(axis=0)
    peak = over[: x.shape[1] * 4].reshape(-1, 4).max(axis=1)
    look = n_of(0.003)
    peak = np.maximum.reduce([np.roll(peak, -k) for k in range(look)])
    gain = np.minimum(1.0, ceiling / np.maximum(peak, 1e-9))
    rel = np.exp(-1 / (SR * 0.08))
    smooth = np.empty_like(gain)
    g = 1.0
    for i in range(len(gain)):
        target = gain[i]
        g = target if target < g else target + (g - target) * rel
        smooth[i] = g
    return x * smooth


def main():
    src, out = sys.argv[1], sys.argv[2]
    data = json.load(open(src))
    mix = build(data["events"], data["duration"], data.get("music", {"bpm": 120}))
    mix = master(mix)
    from scipy.io import wavfile

    pcm = np.clip(mix.T, -1, 1)
    wavfile.write(out, SR, (pcm * 32767).astype(np.int16))
    print(out, f"{mix.shape[1] / SR:.2f}s", "peak", f"{20 * np.log10(np.abs(mix).max()):.2f} dBFS")


if __name__ == "__main__":
    main()

