"""Shrink the YDP Grand Piano SoundFont for bundling in Semitone.

Source: YDP-GrandPiano-SF2-20160804.tar.bz2 from https://freepats.zenvoid.org/Piano/
(FreePats; Zenph Studios Yamaha Disklavier Pro samples; Creative Commons Attribution 3.0).

Only the sample data changes; presets, instruments, zones and envelopes are copied as-is.
Each sample is resampled by register and cut where it has decayed below -50 dB (plus a
0.3 s fade), or at a register cap with a 1.5 s fade, whichever comes first:
  keys below C3   22.05 kHz, at most 9 s
  C3 to B4        32 kHz, at most 6 s
  C5 and up       32 kHz, at most 4 s
Usage: python slim_sf2.py <in.sf2> <out.sf2>   (numpy + scipy)
"""
import struct, sys
from fractions import Fraction
import numpy as np
from scipy.signal import resample_poly

def chunks(data, off, end):
    while off < end:
        cid = data[off:off + 4]; size = struct.unpack('<I', data[off + 4:off + 8])[0]
        yield cid, data[off + 8:off + 8 + size]
        off += 8 + size + (size & 1)

def chunk(cid, payload):
    pad = b'\0' if len(payload) & 1 else b''
    return cid + struct.pack('<I', len(payload)) + payload + pad

def plan(key):
    if key < 48: return 22050, 9.0
    if key < 72: return 32000, 6.0
    return 32000, 4.0

src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
assert data[:4] == b'RIFF' and data[8:12] == b'sfbk'
lists = {}
for cid, body in chunks(data, 12, len(data)):
    assert cid == b'LIST'
    lists[body[:4]] = list(chunks(body, 4, len(body)))
sdta = dict(lists[b'sdta'])
assert b'sm24' not in sdta, '24-bit sample extension not handled'
smpl = np.frombuffer(sdta[b'smpl'], dtype='<i2')
shdr_raw = dict(lists[b'pdta'])[b'shdr']
records = [shdr_raw[i * 46:(i + 1) * 46] for i in range(len(shdr_raw) // 46)]

out_samples, new_records, pos = [], [], 0
for rec in records[:-1]:
    name = rec[:20]
    start, end, ls, le, rate, key, corr, link, stype = struct.unpack('<IIIIIBbHH', rec[20:])
    assert stype == 1, 'only mono samples handled'
    x = smpl[start:end].astype(np.float64)
    new_rate, cap = plan(key)
    ratio = Fraction(new_rate, rate).limit_denominator(1000)
    y = resample_poly(x, ratio.numerator, ratio.denominator) if ratio != 1 else x
    # -50 dB point of a 50 ms RMS envelope
    n = int(new_rate * 0.05); m = max(len(y) // n, 1)
    env = np.sqrt((y[:m * n].reshape(m, n) ** 2).mean(1)) + 1e-9
    above = np.nonzero(20 * np.log10(env / env.max()) > -50)[0]
    quiet_cut = (above[-1] + 1) * n + int(0.3 * new_rate) if len(above) else len(y)
    cap_cut = int(cap * new_rate)
    cut = min(len(y), quiet_cut, cap_cut)
    fade = int((1.5 if cap_cut <= quiet_cut and cap_cut < len(y) else 0.3) * new_rate)
    fade = min(fade, cut // 2)
    y = y[:cut].copy()
    y[cut - fade:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, fade)))
    y = np.clip(np.round(y), -32768, 32767).astype('<i2')
    new_start, new_end = pos, pos + len(y)
    out_samples += [y, np.zeros(46, dtype='<i2')]   # SF2 requires 46 zero points after each sample
    pos = new_end + 46
    # These samples don't loop (sampleModes 0), but the header still needs valid loop points.
    new_records.append(name + struct.pack('<IIIIIBbHH', new_start, new_end, new_start + 8, max(new_end - 8, new_start + 16),
                                         new_rate, key, corr, link, stype))
new_records.append(records[-1])   # terminal EOS record

new_smpl = np.concatenate(out_samples).tobytes()
pdta = b''.join(chunk(cid, b''.join(new_records) if cid == b'shdr' else body) for cid, body in lists[b'pdta'])
info_items = [(cid, body) for cid, body in lists[b'INFO'] if cid != b'ICMT']
comment = b'Modified for Semitone: resampled by register (22.05/32 kHz) and shortened with fades. Original: YDP Grand Piano, FreePats, CC BY 3.0.\0'
info = b''.join(chunk(cid, body) for cid, body in info_items) + chunk(b'ICMT', comment)
body = b'sfbk' + chunk(b'LIST', b'INFO' + info) + chunk(b'LIST', b'sdta' + chunk(b'smpl', new_smpl)) + chunk(b'LIST', b'pdta' + pdta)
open(dst, 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)
print(f'{len(records) - 1} samples, sample data {len(smpl) * 2 / 1e6:.1f} MB -> {len(new_smpl) / 1e6:.1f} MB')
