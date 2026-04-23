"""
BANDxMATE chord-progression evolver.

Runs forever on your GCP VM. Every iteration:
  1. Generates N candidate progressions by mutating top performers
  2. Scores each by complexity + novelty fitness (NOT hard-coded I-IV-V)
  3. Keeps top-K in a rolling library
  4. Writes the library to progressions.json every `SAVE_EVERY` seconds

The HTML app fetches that JSON on load and merges it into its progression
memory — so what the client plays is biased toward whatever this worker
has discovered.

"Complexity" here is deliberately not a neural net. It's a hand-coded fitness
that rewards:
  - Non-obvious chord qualities (not just maj/min/dom7)
  - Large harmonic-distance jumps (tritone subs, chromatic mediants)
  - Variety within the sequence (few repeats)
  - Absence of the default I-V-vi-IV / ii-V-I templates
  - Mild reward for eventual resolution back near the start

This keeps the progressions musical (they still cadence) while actively
pushing away from clichés.

Copy-paste deploy: see cloud/README.md.
"""

import json
import os
import random
import time
from pathlib import Path


# ── Chord table mirrors the CHORDS object in index.html ─────────────────────
#   'iv' = scale-degree intervals from root, in semitones
#   'fm' = consonance metric (higher = more tense — used for harmonic distance)

CHORDS = {
    'maj':    {'iv': [0, 4, 7],           'fm': 1.25},
    'min':    {'iv': [0, 3, 7],           'fm': 1.20},
    'dom7':   {'iv': [0, 4, 7, 10],       'fm': 1.40},
    'maj7':   {'iv': [0, 4, 7, 11],       'fm': 1.30},
    'min7':   {'iv': [0, 3, 7, 10],       'fm': 1.30},
    'dom9':   {'iv': [0, 4, 7, 10, 14],   'fm': 1.45},
    'quar':   {'iv': [0, 5, 10, 15],      'fm': 1.50},  # quartal stack
    'min11':  {'iv': [0, 3, 7, 10, 14, 17], 'fm': 1.55},
    'dim':    {'iv': [0, 3, 6, 9],        'fm': 1.50},
    'aug':    {'iv': [0, 4, 8],           'fm': 1.45},
    'lydian': {'iv': [0, 4, 6, 7, 11],    'fm': 1.35},
}

CHORD_TYPES = list(CHORDS.keys())
OUTPUT_PATH = Path(os.environ.get('BANDX_OUT', './progressions.json'))
SAVE_EVERY = float(os.environ.get('BANDX_SAVE_EVERY', 10.0))
LIBRARY_SIZE = int(os.environ.get('BANDX_LIBRARY_SIZE', 96))
POPULATION = int(os.environ.get('BANDX_POPULATION', 48))
MUTATION_RATE = 0.35


# ── Obvious / overused templates to penalise ────────────────────────────────
# These are the progressions people complain sound "hardcoded." Their presence
# gives a large complexity penalty even if individual chord qualities are fine.

CLICHE_SEQUENCES = {
    # I-IV-V-I family
    ('maj', 'maj', 'dom7', 'maj'),
    ('maj', 'dom7', 'maj', 'maj'),
    # ii-V-I
    ('min7', 'dom7', 'maj7', 'maj7'),
    ('min7', 'dom7', 'maj7'),
    # I-vi-IV-V (50s doo-wop)
    ('maj', 'min', 'maj', 'dom7'),
    # I-V-vi-IV (Pachelbel / pop punk)
    ('maj', 'dom7', 'min', 'maj'),
    # vi-IV-I-V (inverted pop)
    ('min', 'maj', 'maj', 'dom7'),
}


def root_pc_of(chord_type: str) -> int:
    """Pitch class of chord root relative to a notional key root.
    Since our chord_type is quality-only (no root), we approximate 'harmonic
    distance' via the chord's interval stack — different qualities on the
    same root give different bass/color movement in the final mix.
    """
    # Use the second interval (usually the third) as a proxy for brightness
    return CHORDS[chord_type]['iv'][1] if len(CHORDS[chord_type]['iv']) > 1 else 0


def harmonic_distance(a: str, b: str) -> float:
    """Crude distance between two chord qualities. Bigger = more dramatic."""
    iva = set(CHORDS[a]['iv'])
    ivb = set(CHORDS[b]['iv'])
    # Jaccard distance on the interval sets + fm difference
    union = iva | ivb
    inter = iva & ivb
    jacc = 1.0 - (len(inter) / len(union) if union else 1.0)
    fm_diff = abs(CHORDS[a]['fm'] - CHORDS[b]['fm'])
    return 0.6 * jacc + 0.4 * fm_diff


def sequence_complexity(seq: list) -> float:
    """Fitness score in [0, ~2]. Higher = more interesting."""
    if len(seq) < 3:
        return 0.0

    # 1. Variety: how many unique chord qualities?
    variety = len(set(seq)) / len(seq)

    # 2. Mean harmonic distance between adjacent chords
    jumps = [harmonic_distance(seq[i], seq[i + 1]) for i in range(len(seq) - 1)]
    avg_jump = sum(jumps) / len(jumps) if jumps else 0.0

    # 3. Rare-chord bonus (uses chords beyond the four most common ones)
    rare = sum(1 for c in seq if c in ('quar', 'min11', 'dim', 'aug', 'lydian', 'dom9'))
    rare_score = min(1.0, rare / len(seq) * 2)

    # 4. Cliché penalty
    cliche = 0.0
    for k in range(3, 5):
        for i in range(len(seq) - k + 1):
            chunk = tuple(seq[i:i + k])
            if chunk in CLICHE_SEQUENCES:
                cliche += 0.5

    # 5. Mild reward for returning near the start (feels resolved)
    resolution = 1.0 - harmonic_distance(seq[0], seq[-1]) * 0.5

    score = (
        0.25 * variety
        + 0.30 * avg_jump
        + 0.20 * rare_score
        + 0.15 * resolution
        - cliche
    )
    return max(0.0, score)


def random_sequence(length: int = None) -> list:
    if length is None:
        length = random.choice([3, 4, 4, 4, 5, 6, 8])
    return [random.choice(CHORD_TYPES) for _ in range(length)]


def mutate(seq: list) -> list:
    """Single-point mutation (change, insert, delete, swap)."""
    if not seq:
        return random_sequence()
    op = random.random()
    seq = seq[:]
    i = random.randrange(len(seq))
    if op < 0.45:  # change
        seq[i] = random.choice(CHORD_TYPES)
    elif op < 0.70:  # insert
        if len(seq) < 8:
            seq.insert(i, random.choice(CHORD_TYPES))
    elif op < 0.85:  # delete
        if len(seq) > 3:
            del seq[i]
    else:  # swap
        j = random.randrange(len(seq))
        seq[i], seq[j] = seq[j], seq[i]
    return seq


def crossover(a: list, b: list) -> list:
    """Take a prefix of one and a suffix of the other."""
    if not a or not b:
        return a or b
    cut_a = random.randint(1, len(a))
    cut_b = random.randint(0, len(b) - 1)
    child = a[:cut_a] + b[cut_b:]
    return child[:8]


def evolve(library: list, generations: int = 1) -> list:
    """Run one generation of mutation + selection."""
    if not library:
        return [{'seq': random_sequence(), 'score': 0.0, 'uses': 0} for _ in range(POPULATION)]

    for _ in range(generations):
        # Spawn offspring from the top half
        library.sort(key=lambda e: e['score'], reverse=True)
        parents = library[: max(8, len(library) // 2)]
        offspring = []
        while len(offspring) < POPULATION:
            if random.random() < 0.6:
                parent = random.choice(parents)
                child = mutate(parent['seq'])
            else:
                a, b = random.sample(parents, 2)
                child = crossover(a['seq'], b['seq'])
            if random.random() < MUTATION_RATE:
                child = mutate(child)
            score = sequence_complexity(child)
            offspring.append({'seq': child, 'score': score, 'uses': 0})

        # Re-score the existing library (chord table could evolve too, defensively)
        for entry in library:
            entry['score'] = sequence_complexity(entry['seq'])

        # Combine and dedupe by sequence
        combined = {tuple(e['seq']): e for e in library + offspring}
        library = list(combined.values())
        library.sort(key=lambda e: e['score'], reverse=True)
        library = library[:LIBRARY_SIZE]
    return library


def to_storage(library: list) -> dict:
    """Serialize for the HTML client (expects 'seq' as 'chord-chord-chord')."""
    entries = []
    for e in library:
        # Normalize score to 0..1 so client roulette works cleanly
        norm = max(0.0, min(1.0, e['score'] / 2.0))
        entries.append({
            'seq': '-'.join(e['seq']),
            'score': round(norm, 4),
            'uses': int(e.get('uses', 0)),
        })
    return {
        'updated': int(time.time()),
        'library': entries,
    }


def save(library: list, path: Path = OUTPUT_PATH):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(to_storage(library), indent=2))
    tmp.replace(path)


def main():
    # Bootstrap: load prior library if exists
    library = []
    if OUTPUT_PATH.exists():
        try:
            data = json.loads(OUTPUT_PATH.read_text())
            for entry in data.get('library', []):
                seq = entry.get('seq', '').split('-')
                if seq and all(c in CHORDS for c in seq):
                    library.append({
                        'seq': seq,
                        'score': sequence_complexity(seq),
                        'uses': entry.get('uses', 0),
                    })
        except Exception as exc:
            print(f'[bandx-worker] could not read existing {OUTPUT_PATH}: {exc}')

    print(f'[bandx-worker] starting. output={OUTPUT_PATH} lib={len(library)} pop={POPULATION}')
    last_save = 0.0
    while True:
        library = evolve(library, generations=1)
        now = time.time()
        if now - last_save >= SAVE_EVERY:
            save(library)
            top = library[0] if library else None
            if top:
                print(
                    f'[bandx-worker] wrote {len(library)} progressions. '
                    f'top: {"-".join(top["seq"])} score={top["score"]:.3f}'
                )
            last_save = now
        time.sleep(0.05)  # let the CPU breathe


if __name__ == '__main__':
    main()
