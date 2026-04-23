#!/usr/bin/env bash
# BANDxMATE chord-progression worker — one-paste installer.
#
# What this does:
#   1. Installs python3 (+ venv) if missing
#   2. Writes the worker to ~/bandx/chord_worker.py
#   3. Registers a systemd service that runs it forever and auto-restarts
#   4. Verifies the HTTP server responds on 127.0.0.1:8080
#   5. Prints the exact next-steps for the browser and the GCP firewall
#
# Deliberate design:
#   - No GitHub fetch. The worker is embedded in this file.
#   - No gcloud CLI required. If gcloud is there we'll use it, otherwise
#     we print the web-console steps.
#   - No nginx. The worker serves HTTP itself on port 8080.
#   - No pip installs. Python stdlib only.
#   - Plays nice with anything else on the VM (toposim, etc.) via MemoryMax
#     and CPUQuota caps in the systemd unit.
#
# Paste to run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dropkickfriend-hub/BANDxMATE/main/cloud/install.sh)
# Or if you already have the repo on the VM:
#   bash cloud/install.sh

set -euo pipefail

say()  { printf '\033[1;36m[bandx]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bandx]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[bandx]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Sanity ---------------------------------------------------------------
[[ $EUID -eq 0 ]] && warn "running as root is fine but the service will install for root — usually you want to paste this as your normal user"

BANDX_PORT="${BANDX_PORT:-8080}"
BANDX_HOME="$HOME/bandx"
BANDX_USER="$(id -un)"
BANDX_UNIT_NAME="bandx-worker"
BANDX_UNIT_PATH="/etc/systemd/system/${BANDX_UNIT_NAME}.service"

# ── 2. Package manager + python -------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

say "checking prerequisites"
if ! have python3; then
  if   have apt-get; then sudo apt-get update && sudo apt-get install -y python3 python3-venv
  elif have dnf;     then sudo dnf install -y python3
  elif have yum;     then sudo yum install -y python3
  else fail "no package manager found (apt-get/dnf/yum). Install Python 3.7+ manually."
  fi
fi
# python3-venv is a separate apt package on Debian/Ubuntu
if have apt-get && ! python3 -c 'import venv' 2>/dev/null; then
  sudo apt-get install -y python3-venv
fi
python3 --version >/dev/null || fail "python3 still not runnable"

if ! have systemctl; then
  fail "systemd not found. This script assumes a systemd host. Bail out, run the worker manually:  python3 $BANDX_HOME/chord_worker.py"
fi

# ── 3. Lay down the worker -------------------------------------------------
say "installing worker to $BANDX_HOME"
mkdir -p "$BANDX_HOME"

cat > "$BANDX_HOME/chord_worker.py" <<'PYEOF'
"""BANDxMATE chord-progression worker. Pure stdlib. Serves JSON on BANDX_PORT."""
import json, os, random, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

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

PORT         = int(os.environ.get('BANDX_PORT', 8080))
OUTPUT_PATH  = Path(os.environ.get('BANDX_OUT', '/tmp/bandx-progressions.json'))
SAVE_EVERY   = float(os.environ.get('BANDX_SAVE_EVERY', 10.0))
LIBRARY_SIZE = int(os.environ.get('BANDX_LIBRARY_SIZE', 96))
POPULATION   = int(os.environ.get('BANDX_POPULATION', 48))
MUTATION_RATE = 0.35

CLICHE_SEQUENCES = {
    ('maj','maj','dom7','maj'), ('maj','dom7','maj','maj'),
    ('min7','dom7','maj7','maj7'), ('min7','dom7','maj7'),
    ('maj','min','maj','dom7'), ('maj','dom7','min','maj'),
    ('min','maj','maj','dom7'),
}

def harmonic_distance(a, b):
    iva, ivb = set(CHORDS[a]['iv']), set(CHORDS[b]['iv'])
    union, inter = iva | ivb, iva & ivb
    jacc = 1.0 - (len(inter)/len(union) if union else 1.0)
    return 0.6*jacc + 0.4*abs(CHORDS[a]['fm'] - CHORDS[b]['fm'])

def sequence_complexity(seq):
    if len(seq) < 3: return 0.0
    variety = len(set(seq))/len(seq)
    jumps = [harmonic_distance(seq[i], seq[i+1]) for i in range(len(seq)-1)]
    avg_jump = sum(jumps)/len(jumps) if jumps else 0.0
    rare = sum(1 for c in seq if c in ('quar','min11','dim','aug','lydian','dom9'))
    rare_score = min(1.0, rare/len(seq)*2)
    cliche = 0.0
    for k in range(3, 5):
        for i in range(len(seq)-k+1):
            if tuple(seq[i:i+k]) in CLICHE_SEQUENCES: cliche += 0.5
    resolution = 1.0 - harmonic_distance(seq[0], seq[-1]) * 0.5
    return max(0.0, 0.25*variety + 0.30*avg_jump + 0.20*rare_score + 0.15*resolution - cliche)

def random_sequence(length=None):
    if length is None: length = random.choice([3,4,4,4,5,6,8])
    return [random.choice(CHORD_TYPES) for _ in range(length)]

def mutate(seq):
    if not seq: return random_sequence()
    op, seq = random.random(), seq[:]
    i = random.randrange(len(seq))
    if op < 0.45:   seq[i] = random.choice(CHORD_TYPES)
    elif op < 0.70:
        if len(seq) < 8: seq.insert(i, random.choice(CHORD_TYPES))
    elif op < 0.85:
        if len(seq) > 3: del seq[i]
    else:
        j = random.randrange(len(seq)); seq[i], seq[j] = seq[j], seq[i]
    return seq

def crossover(a, b):
    if not a or not b: return a or b
    return (a[:random.randint(1,len(a))] + b[random.randint(0,len(b)-1):])[:8]

def evolve(library, generations=1):
    if not library:
        return [{'seq': random_sequence(), 'score': 0.0, 'uses': 0} for _ in range(POPULATION)]
    for _ in range(generations):
        library.sort(key=lambda e: e['score'], reverse=True)
        parents = library[: max(8, len(library)//2)]
        offspring = []
        while len(offspring) < POPULATION:
            if random.random() < 0.6:
                child = mutate(random.choice(parents)['seq'])
            else:
                a, b = random.sample(parents, 2)
                child = crossover(a['seq'], b['seq'])
            if random.random() < MUTATION_RATE: child = mutate(child)
            offspring.append({'seq': child, 'score': sequence_complexity(child), 'uses': 0})
        for entry in library: entry['score'] = sequence_complexity(entry['seq'])
        combined = {tuple(e['seq']): e for e in library + offspring}
        library = sorted(combined.values(), key=lambda e: e['score'], reverse=True)[:LIBRARY_SIZE]
    return library

def to_storage(library):
    return {
        'updated': int(time.time()),
        'library': [
            {'seq':'-'.join(e['seq']),
             'score':round(max(0.0, min(1.0, e['score']/2.0)), 4),
             'uses': int(e.get('uses', 0))}
            for e in library
        ],
    }

_payload = {'updated': 0, 'library': []}
_lock = threading.Lock()

def _publish(library):
    global _payload
    with _lock:
        _payload = to_storage(library)
    return _payload

def _get():
    with _lock:
        return _payload

def _save_file(payload, path=OUTPUT_PATH):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + '.tmp')
        tmp.write_text(json.dumps(payload, indent=2))
        tmp.replace(path)
    except OSError as exc:
        print(f'[bandx-worker] could not write {path}: {exc}')

class _H(BaseHTTPRequestHandler):
    def _send(self, code, body=b'', ct='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', ct)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if body: self.wfile.write(body)
    def do_OPTIONS(self): self._send(204)
    def do_GET(self):
        p = self.path.split('?',1)[0].rstrip('/')
        if p in ('', '/progressions.json'):
            self._send(200, json.dumps(_get()).encode('utf-8'))
        elif p == '/health':
            self._send(200, b'{"ok":true}')
        else:
            self._send(404, b'{"error":"not found"}')
    def log_message(self, fmt, *args): return

def _serve(port):
    srv = ThreadingHTTPServer(('0.0.0.0', port), _H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f'[bandx-worker] HTTP on 0.0.0.0:{port} (/progressions.json)')

def main():
    library = []
    if OUTPUT_PATH.exists():
        try:
            data = json.loads(OUTPUT_PATH.read_text())
            for entry in data.get('library', []):
                seq = entry.get('seq', '').split('-')
                if seq and all(c in CHORDS for c in seq):
                    library.append({'seq': seq,
                                    'score': sequence_complexity(seq),
                                    'uses': entry.get('uses', 0)})
            print(f'[bandx-worker] restored {len(library)} from {OUTPUT_PATH}')
        except (OSError, ValueError) as exc:
            print(f'[bandx-worker] could not read {OUTPUT_PATH}: {exc}')
    _publish(library)
    _serve(PORT)
    print(f'[bandx-worker] evolver running. pop={POPULATION} libcap={LIBRARY_SIZE}')
    last_save = 0.0
    while True:
        library = evolve(library, 1)
        payload = _publish(library)
        now = time.time()
        if now - last_save >= SAVE_EVERY:
            _save_file(payload)
            top = library[0] if library else None
            if top:
                print(f'[bandx-worker] {len(library)} progressions. top: {"-".join(top["seq"])} score={top["score"]:.3f}')
            last_save = now
        time.sleep(0.05)

if __name__ == '__main__':
    try: main()
    except KeyboardInterrupt: print('[bandx-worker] stopped')
PYEOF

# Venv for isolation from anything else the user has running (e.g. toposim)
if [[ ! -d "$BANDX_HOME/venv" ]]; then
  say "creating venv (no pip installs needed, worker uses stdlib only)"
  python3 -m venv "$BANDX_HOME/venv"
fi

# ── 4. Quick smoke test the script parses -----------------------------------
"$BANDX_HOME/venv/bin/python" -c "import ast; ast.parse(open('$BANDX_HOME/chord_worker.py').read())" \
  || fail "worker script failed to parse — please report"

# ── 5. Systemd unit ---------------------------------------------------------
say "writing systemd unit $BANDX_UNIT_PATH"
sudo tee "$BANDX_UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=BANDxMATE chord-progression evolver
After=network.target

[Service]
Type=simple
User=$BANDX_USER
WorkingDirectory=$BANDX_HOME
Environment=BANDX_PORT=$BANDX_PORT
Environment=BANDX_SAVE_EVERY=10
Environment=BANDX_POPULATION=48
Environment=BANDX_LIBRARY_SIZE=96
ExecStart=$BANDX_HOME/venv/bin/python $BANDX_HOME/chord_worker.py
Restart=always
RestartSec=5
Nice=10
MemoryMax=256M
CPUQuota=30%
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$BANDX_UNIT_NAME" >/dev/null
sudo systemctl restart "$BANDX_UNIT_NAME"

# ── 6. Wait for the server to come up --------------------------------------
say "waiting for worker to start on 127.0.0.1:$BANDX_PORT"
for i in {1..20}; do
  if curl -fsS "http://127.0.0.1:$BANDX_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! curl -fsS "http://127.0.0.1:$BANDX_PORT/health" >/dev/null; then
  warn "worker didn't come up in 10s. Dumping last 30 log lines:"
  sudo journalctl -u "$BANDX_UNIT_NAME" -n 30 --no-pager || true
  fail "install aborted. Fix the error shown above and rerun."
fi

say "✓ worker running on port $BANDX_PORT"

# ── 7. Detect public IP -----------------------------------------------------
PUB_IP=""
if have curl; then
  PUB_IP="$(curl -fsSL --max-time 3 ifconfig.me 2>/dev/null || true)"
fi
if [[ -z "$PUB_IP" ]]; then
  PUB_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -z "$PUB_IP" ]] && PUB_IP="YOUR_VM_EXTERNAL_IP"

# ── 8. Try to open the firewall via gcloud if it's available ---------------
FW_STATUS="manual"
if have gcloud; then
  if gcloud compute firewall-rules describe allow-bandx-8080 >/dev/null 2>&1; then
    FW_STATUS="already_open"
  else
    if gcloud compute firewall-rules create allow-bandx-8080 \
         --allow "tcp:$BANDX_PORT" \
         --target-tags=bandx \
         --description="Allow BANDxMATE chord-worker HTTP" >/dev/null 2>&1; then
      FW_STATUS="created"
      ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"
      INST="$(hostname)"
      if [[ -n "$ZONE" ]]; then
        gcloud compute instances add-tags "$INST" --tags=bandx --zone="$ZONE" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

# ── 9. Final summary -------------------------------------------------------
cat <<SUMMARY

  ╭──────────────────────────────────────────────────────────────────╮
  │  BANDxMATE worker installed and running                          │
  ╰──────────────────────────────────────────────────────────────────╯

  Local health check:
    curl http://127.0.0.1:$BANDX_PORT/progressions.json | head

  Service control:
    sudo systemctl status  $BANDX_UNIT_NAME
    sudo systemctl restart $BANDX_UNIT_NAME
    sudo systemctl stop    $BANDX_UNIT_NAME
    journalctl -u $BANDX_UNIT_NAME -f

SUMMARY

case "$FW_STATUS" in
  created)
    echo "  Firewall: opened tcp:$BANDX_PORT via gcloud for tag 'bandx'."
    echo "  If this VM didn't already have the 'bandx' tag applied, add it now:"
    echo "  GCP console → Compute Engine → VM instances → click $HOSTNAME →"
    echo "  Edit → Network tags → add 'bandx' → Save"
    ;;
  already_open)
    echo "  Firewall: tcp:$BANDX_PORT already open (rule allow-bandx-8080 exists)."
    ;;
  manual)
    echo "  Firewall: gcloud not present or not usable — open the port manually:"
    echo "    GCP console → VPC network → Firewall → Create rule"
    echo "      name:       allow-bandx-$BANDX_PORT"
    echo "      targets:    all instances in the network  (simplest)"
    echo "      src IP:     0.0.0.0/0"
    echo "      protocols:  tcp, port $BANDX_PORT"
    ;;
esac

cat <<NEXT

  ── Wire the HTML app to this worker ─────────────────────────────

  1. Open the BANDxMATE app in your browser.
  2. Press F12 → Console. Paste:

     localStorage.setItem('bandx.cloudUrl','http://$PUB_IP:$BANDX_PORT/progressions.json');location.reload();

  3. After reload, you should see in the console:
       [Cloud] Merged N discovered progressions. Library: NN

  That's it. The worker runs forever, auto-restarts on reboot, capped
  at 256 MB / 30% CPU so it can't starve anything else on this VM.
NEXT
