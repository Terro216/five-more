"""Generate the app's original, short PCM alarm loops (no downloaded audio)."""
import math
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RATE = 22050
TONES = {
    'sunrise': ([261.63, 329.63, 392.0, 523.25], .7),
    'arcade': ([523.25, 659.25, 783.99, 1046.5, 783.99, 659.25], .18),
    'pulse': ([440.0, 0, 587.33, 0, 880.0, 0], .22),
}
for name, (notes, beat) in TONES.items():
    samples = []
    for frequency in notes * 2:
        for i in range(int(RATE * beat)):
            t = i / RATE
            envelope = min(1, t / .02) * min(1, (beat - t) / .05)
            value = (math.sin(2 * math.pi * frequency * t) + .2 * math.sin(4 * math.pi * frequency * t)) if frequency else 0
            samples.append(int(value * envelope * 12000))
    destination = ROOT / 'android/app/src/main/res/raw' / f'{name}.wav'
    with wave.open(str(destination), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        audio.writeframes(struct.pack(f'<{len(samples)}h', *samples))
    ios = ROOT / 'ios/Runner/Sounds'
    ios.mkdir(exist_ok=True)
    (ios / f'{name}.wav').write_bytes(destination.read_bytes())
(ROOT / 'ios/Runner/Sounds/alarm_tone.wav').write_bytes((ROOT / 'android/app/src/main/res/raw/alarm_tone.wav').read_bytes())
