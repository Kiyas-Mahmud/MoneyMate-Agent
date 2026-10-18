"""
Sound design for the MoneyMate intro: an original music bed and motion sound effects, all synthesized here
(no samples, no third-party music), synced to the animation timings in index.html.

    python sound.py out.wav            # 60 s, 48 kHz stereo WAV
"""

import sys

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

SR = 48_000
DUR = 60.0
N = int(SR * DUR)
rng = np.random.default_rng(7)


def hz(note: str) -> float:
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    name, octave = note[:-1], int(note[-1])
    return 440.0 * 2 ** ((names[name] + 12 * (octave + 1) - 69) / 12)


def t_axis(dur):
    return np.arange(int(SR * dur)) / SR


def lowpass(x, f, order=2):
    return sosfilt(butter(order, f, "low", fs=SR, output="sos"), x)


def highpass(x, f, order=2):
    return sosfilt(butter(order, f, "high", fs=SR, output="sos"), x)


def bandpass(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


def place(bus, sig, at, gain=1.0, pan=0.0):
    """Mixes a mono signal into a stereo bus at time `at` (s) with equal-power panning (-1 left .. 1 right)."""
    i = int(at * SR)
    if i >= N:
        return
    sig = sig[: N - i] * gain
    a = (pan + 1) * np.pi / 4
    bus[i:i + len(sig), 0] += sig * np.cos(a)
    bus[i:i + len(sig), 1] += sig * np.sin(a)


def env(n, attack, release, curve=3.0):
    e = np.ones(n)
    a, r = int(attack * SR), int(release * SR)
    if a:
        e[:a] = np.linspace(0, 1, a) ** 1.5
    if r:
        e[-r:] *= np.linspace(1, 0, r) ** curve
    return e


def reverb_ir(length=2.4, damp=3.2):
    t = t_axis(length)
    ir = rng.standard_normal((len(t), 2)) * np.exp(-damp * t)[:, None]
    ir[:, 0] = lowpass(ir[:, 0], 6000)
    ir[:, 1] = lowpass(ir[:, 1], 6000)
    return ir / np.abs(ir).sum(axis=0).max() * 6


def reverb(bus, wet, ir):
    out = np.stack([fftconvolve(bus[:, c], ir[:, c])[:N] for c in range(2)], axis=1)
    return bus + out * wet


# ---------------------------------------------------------------------------------------------------------
# Music bed: 100 BPM, one chord per bar (2.4 s), Fmaj7 - Am7 - Cmaj7 - G6/9 (airy, calm, confident)
# ---------------------------------------------------------------------------------------------------------
BPM = 100
BEAT = 60 / BPM
BAR = BEAT * 4
CHORDS = [
    (["F3", "A3", "C4", "E4"], "F2"),
    (["A3", "C4", "E4", "G4"], "A2"),
    (["C4", "E4", "G4", "B4"], "C3"),
    (["G3", "B3", "D4", "A4"], "G2"),
]


def section_level(t):
    """Overall intensity over time (0..1): calm intro, lift with the phone, peak, gentle landing."""
    pts = [(0, .55), (5, .65), (10.6, .7), (11.0, .9), (20, .95), (29, .85), (31, 1.0), (46, 1.0),
           (52.9, .9), (53.6, .8), (58.4, .75), (60, 0)]
    xs, ys = zip(*pts)
    return np.interp(t, xs, ys)


def saw_pad(f, n):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for det in (-0.12, 0.0, 0.11):                         # three slightly detuned voices (cents-ish)
        ff = f * 2 ** (det / 12)
        ph = rng.uniform(0, 2 * np.pi)
        for k in range(1, 10):
            out += np.sin(2 * np.pi * ff * k * t + ph * k) / k
    return out / 9


def music():
    bus = np.zeros((N, 2))
    nbars = int(np.ceil(DUR / BAR)) + 1
    # pad: crossfading chords
    for b in range(nbars):
        notes, root = CHORDS[b % 4]
        start = b * BAR - .4
        dur = BAR + 1.4
        n = int(dur * SR)
        sig = sum(saw_pad(hz(x), n) for x in notes)
        sig = lowpass(sig, 1500, 2) * env(n, .9, 1.3, 2.0)
        for c, pan in ((0, -.35), (1, .35)):
            place(bus, sig * (.9 if c == 0 else 1.0), max(start, 0) + (0.012 if c else 0), .05, pan)
    # plucked arpeggio, 8th notes, from 1.9 s; quieter in the problem scene
    pattern = [0, 1, 2, 3, 2, 1, 2, 3]
    eighth = BEAT / 2
    k = 0
    tt = 1.9
    while tt < 59.2:
        b = int(tt // BAR)
        notes, _ = CHORDS[b % 4]
        f = hz(notes[pattern[k % 8]]) * 2
        n = int(.9 * SR)
        x = t_axis(.9)
        s = (np.sin(2 * np.pi * f * x) + .25 * np.sin(4 * np.pi * f * x) + .08 * np.sin(6 * np.pi * f * x))
        s *= np.exp(-x * 6.5) * env(n, .004, .05)
        s = lowpass(s, 4200)
        g = .045 * (0.8 if 5 < tt < 11 else 1.0) * (0.85 + .15 * ((k % 4) == 0))
        place(bus, s, tt, g, -.45 if k % 2 else .45)
        k += 1
        tt += eighth
    # sub bass from the phone entrance
    for b in range(nbars):
        start = b * BAR
        if start < 10.9 or start > 55:
            continue
        _, root = CHORDS[b % 4]
        n = int((BAR + .5) * SR)
        x = t_axis(BAR + .5)
        s = np.sin(2 * np.pi * hz(root) * x) + .15 * np.sin(4 * np.pi * hz(root) * x)
        s *= env(n, .25, 1.0, 1.5)
        place(bus, s, start, .045)
    # soft pulse: low "thump" on beats 1 and 3, airy hats on off-beats (from 11 s, hats from 20 s)
    beat = 0
    tt = 0.0
    while tt < 53.4:
        if tt >= 10.95:
            if beat % 2 == 0:
                x = t_axis(.35)
                f = 52 + 70 * np.exp(-x * 30)
                s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-x * 11)
                place(bus, lowpass(s, 900), tt, .06)
            if tt >= 19.9:
                x = t_axis(.08)
                s = highpass(rng.standard_normal(len(x)), 7000) * np.exp(-x * 60)
                place(bus, s, tt + BEAT / 2, .012, .3 if beat % 2 else -.3)
        beat += 1
        tt += BEAT
    level = section_level(np.arange(N) / SR)[:, None]
    return bus * level


# ---------------------------------------------------------------------------------------------------------
# Motion sound effects
# ---------------------------------------------------------------------------------------------------------
def whoosh(dur=.5, lo=300, hi=3000, up=True, gain=1.7):
    n = int(dur * SR)
    x = np.linspace(0, 1, n)
    noise = rng.standard_normal(n)
    sweep = (lo + (hi - lo) * (x if up else 1 - x))
    # moving band: filter in short blocks with a sliding centre frequency
    out = np.zeros(n)
    blk = 512
    for i in range(0, n, blk):
        c = sweep[min(i, n - 1)]
        seg = noise[max(0, i - 2048):i + blk]
        y = bandpass(seg, max(c * .6, 40), min(c * 1.6, SR / 2 - 100))
        out[i:i + blk] = y[-len(out[i:i + blk]):]
    shape = np.sin(np.pi * x) ** 1.6
    return out * shape * gain


def tap():
    x = t_axis(.09)
    click = np.sin(2 * np.pi * 1900 * x) * np.exp(-x * 120)
    body = np.sin(2 * np.pi * 420 * x) * np.exp(-x * 55)
    return lowpass(click * .5 + body, 6000)


def pop(f=880):
    x = t_axis(.22)
    ff = f * (1 + .35 * np.exp(-x * 40))
    s = np.sin(2 * np.pi * np.cumsum(ff) / SR) * np.exp(-x * 22)
    return s * env(len(x), .003, .03)


def bell(f, dur=1.6):
    x = t_axis(dur)
    s = (np.sin(2 * np.pi * f * x) + .45 * np.sin(2 * np.pi * f * 2.76 * x) * np.exp(-x * 3)
         + .2 * np.sin(2 * np.pi * f * 5.4 * x) * np.exp(-x * 6))
    return s * np.exp(-x * 2.6) * env(len(x), .002, .2)


def marimba(f, dur=.9):
    x = t_axis(dur)
    s = np.sin(2 * np.pi * f * x) + .3 * np.sin(2 * np.pi * f * 4 * x) * np.exp(-x * 18)
    return s * np.exp(-x * 5.5) * env(len(x), .002, .1)


def thud():
    x = t_axis(.5)
    f = 70 + 90 * np.exp(-x * 25)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-x * 9)


def alert():
    """Soft, low two-note caution (not an alarm): a falling minor second over a thud."""
    out = np.zeros(int(.9 * SR))
    for i, (f, at) in enumerate(((hz("E4"), 0), (hz("D#4"), .16))):
        s = bell(f, .7) * .55
        j = int(at * SR)
        out[j:j + len(s)] += s[: len(out) - j]
    t = thud()
    out[:len(t)] += t * .6
    return lowpass(out, 3500)


def scan(dur=1.15):
    x = t_axis(dur)
    f = 380 + 260 * (x / dur) ** 1.2
    s = np.sin(2 * np.pi * np.cumsum(f) / SR) * (.6 + .4 * np.sin(2 * np.pi * 9 * x))
    return lowpass(s, 2500) * env(len(x), .12, .18)


def shimmer(dur=1.0):
    x = t_axis(dur)
    s = sum(np.sin(2 * np.pi * hz(n) * 2 * x + i) * np.exp(-x * (3 + i)) for i, n in enumerate(["E5", "G5", "B5", "D6"]))
    return highpass(s, 600) * env(len(x), .05, .4) * .5


def tick():
    x = t_axis(.05)
    return highpass(rng.standard_normal(len(x)), 2500) * np.exp(-x * 140)


def sfx():
    bus = np.zeros((N, 2))
    # brand signature: four marimba notes as the bars rise, airy swell under the wordmark
    for i, n in enumerate(["C5", "E5", "G5", "B5"]):
        place(bus, marimba(hz(n)), .25 + i * .09, .22, -.3 + i * .2)
    place(bus, whoosh(1.1, 200, 1800), .75, .06)
    place(bus, whoosh(.6, 2500, 400, up=False), 4.3, .05)                 # brand lifts away
    # problem chips
    for i in range(3):
        place(bus, pop(780 + i * 110), 6.15 + i * .2, .16, .4)
    place(bus, alert(), 8.75, .3, .35)                                     # the fake invoice chip
    place(bus, whoosh(.55, 2200, 500, up=False), 10.35, .05, .3)
    # phone enters
    place(bus, whoosh(1.0, 150, 2400), 10.85, .11, .25)
    place(bus, thud(), 11.35, .12, .2)
    # agent: tap "Pay with agent", screen pushes in
    place(bus, tap(), 13.55, .3, .25)
    place(bus, whoosh(.55, 600, 4200), 13.9, .08, .35)
    # verify sheet
    place(bus, tap(), 19.55, .3, .25)
    place(bus, whoosh(.7, 250, 2600), 19.9, .09, .2)
    # fingerprint: badge, scan, success
    place(bus, pop(660), 22.0, .14, .2)
    place(bus, scan(), 22.35, .09, .2)
    place(bus, bell(hz("E6")), 23.52, .2, .15)
    place(bus, bell(hz("B6")), 23.64, .14, .3)
    # receipt
    place(bus, shimmer(), 24.4, .22, .2)
    # scam check
    place(bus, whoosh(.55, 600, 4200), 29.0, .08, .35)
    place(bus, tap(), 30.55, .3, .25)
    place(bus, alert(), 30.95, .34, .2)
    for i in range(3):                                                     # threats: muted "blocked" pops
        place(bus, lowpass(pop(420 - i * 30), 1800), 32.3 + i * .32, .22, -.35)
    # payment history and report
    place(bus, whoosh(.55, 600, 4200), 38.0, .08, .35)
    place(bus, whoosh(.5, 400, 2200), 41.2, .05, .25)
    place(bus, bell(hz("G5"), 1.2), 42.6, .14, -.1)
    place(bus, bell(hz("D6"), 1.2), 42.72, .1, -.1)
    # audit log and chain
    place(bus, whoosh(.55, 600, 4200), 45.95, .08, .35)
    place(bus, tap(), 46.6, .3, .35)
    place(bus, whoosh(.7, 250, 2600), 46.9, .09, .25)
    for i in range(4):
        place(bus, pop(560 + i * 90) * .8, 47.9 + i * .38, .13, -.4 + i * .1)
        if i < 3:
            place(bus, tick(), 48.2 + i * .38, .05, -.3 + i * .1)
    place(bus, bell(hz("A5"), 1.4), 49.1, .1, -.05)                        # the Sepolia block lands
    # phone exits, end card
    place(bus, whoosh(.9, 2600, 250, up=False), 52.9, .09, .25)
    for i, n in enumerate(["C5", "E5", "G5", "B5"]):
        place(bus, marimba(hz(n)), 53.75 + i * .09, .22, -.3 + i * .2)
    for n, g in (("C4", .1), ("G4", .08), ("E5", .07), ("B5", .05)):     # resolving Cmaj7 bell chord
        place(bus, bell(hz(n), 4.5), 54.3, g)
    return bus


def main(out_path):
    ir = reverb_ir()
    m = reverb(music(), .35, ir)
    s = reverb(sfx(), .18, ir)
    mix = m * .9 + s
    mix = highpass(mix.T, 28).T                                            # clean the sub-rumble
    fade = np.ones(N)
    fi = int(.25 * SR)
    fade[:fi] = np.linspace(0, 1, fi)
    fo = int(1.6 * SR)
    fade[-fo:] = np.linspace(1, 0, fo) ** 2
    mix *= fade[:, None]
    mix = np.tanh(mix * 1.6) / np.tanh(1.6)                                # gentle soft-clip glue
    mix /= np.abs(mix).max() / .89
    pcm = (mix * 32767).astype("<i2")
    import wave
    with wave.open(out_path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("wrote", out_path)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "sound.wav")
