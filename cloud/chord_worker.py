"""
BANDxMATE chord-progression evolver.

Runs forever. Every iteration:
  1. Generates N candidate progressions by mutating top performers
  2. Scores each by complexity + novelty fitness (NOT hard-coded I-IV-V)
  3. Keeps top-K in a rolling library
  4. Serves the library as JSON on http://0.0.0.0:BANDX_PORT/progressions.json

No external dependencies. Pure Python stdlib. Works on any machine with
Python 3.7+.

The HTML app (index.html) calls fetchCloudProgressions() on boot, merges
the served progressions into progressionMemory.library, and lets
structureEngine.nextChord pick from them — so the band actively plays
what the worker has discovered.

"Complexity" is deliberately not a neural net. Hand-coded fitness rewards:
  - Non-obvious chord qualities (not just maj/min/dom7)
  - Large harmonic-distance jumps (tritone subs, chromatic mediants)
  - Variety within the sequence (few repeats)
  - Absence of clichéd I-V-vi-IV / ii-V-I templates
  - Mild reward for eventual resolution back near the start

Config via env vars (all optional):
  BANDX_PORT         default 8080 — HTTP port
  BANDX_OUT          default /tmp/bandx-progressions.json — file mirror
  BANDX_SAVE_EVERY   default 10   — seconds between file writes
  BANDX_POPULATION   default 48   — candidates per generation
  BANDX_LIBRARY_SIZE default 96   — max retained progressions
"""

import json
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


# ── Chord table mirrors the CHORDS object in index.html ─────────────────────
CHORDS = {
    'maj':    {'iv': [0, 4, 7],           'fm': 1.25},
    'min':    {'iv': [0, 3, 7],           'fm': 1.20},
    'dom7':   {'iv': [0, 4, 7, 10],       'fm': 1.40},
    'maj7':   {'iv': [0, 4, 7, 11],       'fm': 1.30},
    'min7':   {'iv': [0, 3, 7, 10],       'fm': 1.30},
    'dom9':   {'iv': [0, 4, 7, 10, 14],   'fm': 1.45},
    'quar':   {'iv': [0, 5, 10, 15],      'fm': 1.50},
    'min11':  {'iv': [0, 3, 7, 10, 14, 17], 'fm': 1.55},
    'dim':    {'iv': [0, 3, 6, 9],        'fm': 1.50},
    'aug':    {'iv': [0, 4, 8],           'fm': 1.45},
    'lydian': {'iv': [0, 4, 6, 7, 11],    'fm': 1.35},
}
CHORD_TYPES = list(CHORDS.keys())

PORT          = int(os.environ.get('BANDX_PORT', 8080))
OUTPUT_PATH   = Path(os.environ.get('BANDX_OUT', '/tmp/bandx-progressions.json'))
SAVE_EVERY    = float(os.environ.get('BANDX_SAVE_EVERY', 10.0))
LIBRARY_SIZE  = int(os.environ.get('BANDX_LIBRARY_SIZE', 96))
POPULATION    = int(os.environ.get('BANDX_POPULATION', 48))
MUTATION_RATE = 0.35


# ── Clichés to penalise ─────────────────────────────────────────────────────
CLICHE_SEQUENCES = {
    ('maj', 'maj', 'dom7', 'maj'),
    ('maj', 'dom7', 'maj', 'maj'),
    ('min7', 'dom7', 'maj7', 'maj7'),
    ('min7', 'dom7', 'maj7'),
    ('maj', 'min', 'maj', 'dom7'),
    ('maj', 'dom7', 'min', 'maj'),
    ('min', 'maj', 'maj', 'dom7'),
}


def harmonic_distance(a, b):
    """Crude distance between two chord qualities. Bigger = more dramatic."""
    iva = set(CHORDS[a]['iv'])
    ivb = set(CHORDS[b]['iv'])
    union = iva | ivb
    inter = iva & ivb
    jacc = 1.0 - (len(inter) / len(union) if union else 1.0)
    fm_diff = abs(CHORDS[a]['fm'] - CHORDS[b]['fm'])
    return 0.6 * jacc + 0.4 * fm_diff


def sequence_complexity(seq):
    """Fitness score. Higher = more interesting."""
    if len(seq) < 3:
        return 0.0

    variety = len(set(seq)) / len(seq)
    jumps = [harmonic_distance(seq[i], seq[i + 1]) for i in range(len(seq) - 1)]
    avg_jump = sum(jumps) / len(jumps) if jumps else 0.0
    rare = sum(1 for c in seq if c in ('quar', 'min11', 'dim', 'aug', 'lydian', 'dom9'))
    rare_score = min(1.0, rare / len(seq) * 2)

    cliche = 0.0
    for k in range(3, 5):
        for i in range(len(seq) - k + 1):
            chunk = tuple(seq[i:i + k])
            if chunk in CLICHE_SEQUENCES:
                cliche += 0.5

    resolution = 1.0 - harmonic_distance(seq[0], seq[-1]) * 0.5

    score = (
        0.25 * variety
        + 0.30 * avg_jump
        + 0.20 * rare_score
        + 0.15 * resolution
        - cliche
    )
    return max(0.0, score)


def random_sequence(length=None):
    if length is None:
        length = random.choice([3, 4, 4, 4, 5, 6, 8])
    return [random.choice(CHORD_TYPES) for _ in range(length)]


def mutate(seq):
    if not seq:
        return random_sequence()
    op = random.random()
    seq = seq[:]
    i = random.randrange(len(seq))
    if op < 0.45:
        seq[i] = random.choice(CHORD_TYPES)
    elif op < 0.70:
        if len(seq) < 8:
            seq.insert(i, random.choice(CHORD_TYPES))
    elif op < 0.85:
        if len(seq) > 3:
            del seq[i]
    else:
        j = random.randrange(len(seq))
        seq[i], seq[j] = seq[j], seq[i]
    return seq


def crossover(a, b):
    if not a or not b:
        return a or b
    cut_a = random.randint(1, len(a))
    cut_b = random.randint(0, len(b) - 1)
    return (a[:cut_a] + b[cut_b:])[:8]


def evolve(library, generations=1):
    if not library:
        return [{'seq': random_sequence(), 'score': 0.0, 'uses': 0} for _ in range(POPULATION)]

    for _ in range(generations):
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

        for entry in library:
            entry['score'] = sequence_complexity(entry['seq'])

        combined = {tuple(e['seq']): e for e in library + offspring}
        library = list(combined.values())
        library.sort(key=lambda e: e['score'], reverse=True)
        library = library[:LIBRARY_SIZE]
    return library


def to_storage(library):
    entries = []
    for e in library:
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


# ── Shared state: HTTP server reads this, evolver writes this ───────────────
_latest_payload = {'updated': 0, 'library': []}
_payload_lock = threading.Lock()


def _publish(library):
    payload = to_storage(library)
    with _payload_lock:
        global _latest_payload
        _latest_payload = payload
    return payload


def _get_payload():
    with _payload_lock:
        return _latest_payload


def _save_file(payload, path=OUTPUT_PATH):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + '.tmp')
        tmp.write_text(json.dumps(payload, indent=2))
        tmp.replace(path)
    except OSError as exc:
        print(f'[bandx-worker] could not write {path}: {exc}')


# ── Billboard: cross-user Top-10-per-genre store ──────────────────────────
# Metadata-only. Audio is never uploaded here -- only titles, socials URLs,
# per-voice ratings, and computed scores. Entries expire after 60 days so
# the chart is always fresh. Weekly champions are snapshotted separately.
BILLBOARD_PATH   = Path(os.environ.get('BANDX_BILLBOARD', '/tmp/bandx-billboard.json'))
BB_MAX_ENTRIES   = 2000           # hard cap so one bad actor can't bomb the db
BB_EXPIRE_SEC    = 60 * 24 * 3600 # entries older than this drop off the chart
BB_LOCK = threading.Lock()
_BB_STATE = {'entries': {}, 'champs': {}}  # id -> entry; genre -> snapshot


def _bb_load():
    if BILLBOARD_PATH.exists():
        try:
            data = json.loads(BILLBOARD_PATH.read_text())
            _BB_STATE['entries'] = data.get('entries', {}) or {}
            _BB_STATE['champs']  = data.get('champs', {})  or {}
        except (OSError, ValueError) as exc:
            print(f'[bandx-billboard] could not read {BILLBOARD_PATH}: {exc}')


def _bb_save():
    try:
        tmp = BILLBOARD_PATH.with_suffix('.tmp')
        tmp.write_text(json.dumps(_BB_STATE, indent=2))
        tmp.replace(BILLBOARD_PATH)
    except OSError as exc:
        print(f'[bandx-billboard] could not write {BILLBOARD_PATH}: {exc}')


def _bb_expire():
    now = time.time()
    with BB_LOCK:
        dead = [k for k, e in _BB_STATE['entries'].items()
                if now - (e.get('ts', 0) / 1000) > BB_EXPIRE_SEC]
        for k in dead:
            del _BB_STATE['entries'][k]


def _bb_score(e):
    """Deep-learned rank: avg rating * log(count+1) * recency decay."""
    age_hrs = max(0.0, (time.time() - e.get('ts', 0) / 1000) / 3600)
    recency = 2.71828 ** (-age_hrs / (24 * 7))
    r  = float(e.get('totalRating', 0.0))
    n  = int(e.get('ratingCount', 0))
    import math
    return r * math.log2(n + 2) * (0.6 + 0.4 * recency)


def _bb_top(genre, n=10):
    _bb_expire()
    with BB_LOCK:
        pool = [e for e in _BB_STATE['entries'].values()
                if not genre or e.get('genre') == genre]
    pool.sort(key=_bb_score, reverse=True)
    return pool[:n]


def _bb_update_champs():
    """Snapshot #1 per genre; called once per request naturally (cheap)."""
    GENRES = ['jazz','pop','edm','hiphop','westcoast','eastcoast','african','indian']
    for g in GENRES:
        top = _bb_top(g, 1)
        if top:
            _BB_STATE['champs'][g] = {
                'entryId': top[0].get('id'),
                'title':   top[0].get('title'),
                'socials': top[0].get('socials', ''),
                'score':   _bb_score(top[0]),
                'snapshotTs': int(time.time() * 1000),
            }


# ── HTTP handler: CORS + /progressions.json + /billboard/* ────────────────
class _Handler(BaseHTTPRequestHandler):
    def _send(self, code, body=b'', content_type='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _read_body(self):
        try:
            n = int(self.headers.get('Content-Length', 0) or 0)
            raw = self.rfile.read(n) if n > 0 else b''
            return json.loads(raw.decode('utf-8')) if raw else {}
        except (ValueError, OSError):
            return None

    def do_OPTIONS(self):  # CORS preflight
        self._send(204)

    def do_GET(self):
        path = self.path.split('?', 1)[0].rstrip('/')
        qs = {}
        if '?' in self.path:
            for kv in self.path.split('?', 1)[1].split('&'):
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    qs[k] = v

        if path in ('', '/progressions.json'):
            body = json.dumps(_get_payload()).encode('utf-8')
            self._send(200, body)
        elif path == '/health':
            self._send(200, b'{"ok":true}')
        elif path == '/billboard/top':
            genre = qs.get('genre')
            try:
                n = max(1, min(50, int(qs.get('n', '10'))))
            except ValueError:
                n = 10
            _bb_update_champs()
            body = json.dumps({
                'entries': _bb_top(genre, n),
                'champs':  _BB_STATE['champs'],
            }).encode('utf-8')
            self._send(200, body)
        else:
            self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        path = self.path.split('?', 1)[0].rstrip('/')
        if path == '/billboard/upload':
            data = self._read_body()
            if not data or not isinstance(data, dict):
                self._send(400, b'{"error":"invalid json"}'); return
            eid = str(data.get('id') or f'bb-{int(time.time()*1000)}-{random.randint(1000,9999)}')
            with BB_LOCK:
                # Never store raw audio -- just metadata
                _BB_STATE['entries'][eid] = {
                    'id':         eid,
                    'title':      str(data.get('title', 'Untitled'))[:140],
                    'socials':    str(data.get('socials', ''))[:240],
                    'genre':      str(data.get('genre', 'pop'))[:24],
                    'ts':         int(data.get('ts') or time.time() * 1000),
                    'weekId':     str(data.get('weekId', ''))[:16],
                    'ratings':    data.get('ratings', {'drum':0,'bass':0,'mid':0,'lead':0}),
                    'ratingCounts': data.get('ratingCounts', {'drum':0,'bass':0,'mid':0,'lead':0}),
                    'totalRating':float(data.get('totalRating', 0) or 0),
                    'ratingCount':int(data.get('ratingCount', 0) or 0),
                }
                # Enforce cap -- drop lowest-scoring on overflow
                if len(_BB_STATE['entries']) > BB_MAX_ENTRIES:
                    sorted_ids = sorted(_BB_STATE['entries'].values(), key=_bb_score)
                    for e in sorted_ids[:len(sorted_ids) - BB_MAX_ENTRIES]:
                        _BB_STATE['entries'].pop(e['id'], None)
            _bb_save()
            self._send(200, json.dumps({'ok': True, 'id': eid}).encode('utf-8'))
        elif path == '/billboard/rate':
            data = self._read_body()
            if not data:
                self._send(400, b'{"error":"invalid json"}'); return
            eid = str(data.get('id', ''))
            voice = str(data.get('voice', ''))
            stars = float(data.get('stars', 0) or 0)
            if voice not in ('drum','bass','mid','lead') or not (1 <= stars <= 5):
                self._send(400, b'{"error":"bad voice or stars"}'); return
            with BB_LOCK:
                e = _BB_STATE['entries'].get(eid)
                if not e:
                    self._send(404, b'{"error":"no such entry"}'); return
                n = int(e['ratingCounts'].get(voice, 0) or 0)
                prev = float(e['ratings'].get(voice, 0) or 0)
                e['ratings'][voice] = (prev * n + stars) / (n + 1)
                e['ratingCounts'][voice] = n + 1
                tot, cnt = 0.0, 0
                for k in ('drum','bass','mid','lead'):
                    c = int(e['ratingCounts'].get(k, 0) or 0)
                    if c:
                        tot += float(e['ratings'][k]) * c
                        cnt += c
                e['totalRating'] = tot / cnt if cnt else 0.0
                e['ratingCount'] = cnt
            _bb_save()
            self._send(200, json.dumps({'ok': True}).encode('utf-8'))
        else:
            self._send(404, b'{"error":"not found"}')

    # Silence the default per-request stderr logging (keeps journalctl clean)
    def log_message(self, fmt, *args):
        return


def _start_server(port):
    srv = ThreadingHTTPServer(('0.0.0.0', port), _Handler)
    thread = threading.Thread(target=srv.serve_forever, name='bandx-http', daemon=True)
    thread.start()
    print(f'[bandx-worker] HTTP server on 0.0.0.0:{port} (/progressions.json)')
    return srv


def main():
    library = []
    # Load prior library if the output file still exists from a previous run
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
            print(f'[bandx-worker] restored {len(library)} from {OUTPUT_PATH}')
        except (OSError, ValueError) as exc:
            print(f'[bandx-worker] could not read existing {OUTPUT_PATH}: {exc}')

    _bb_load()
    print(f'[bandx-billboard] loaded {len(_BB_STATE["entries"])} entries')
    _publish(library)
    _start_server(PORT)
    print(f'[bandx-worker] evolver starting. pop={POPULATION} libcap={LIBRARY_SIZE}')

    last_save = 0.0
    while True:
        library = evolve(library, generations=1)
        payload = _publish(library)
        now = time.time()
        if now - last_save >= SAVE_EVERY:
            _save_file(payload)
            top = library[0] if library else None
            if top:
                score_str = f"{top['score']:.3f}"
                print(
                    f'[bandx-worker] {len(library)} progressions. '
                    f'top: {"-".join(top["seq"])} score={score_str}'
                )
            last_save = now
        time.sleep(0.05)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('[bandx-worker] stopped')
