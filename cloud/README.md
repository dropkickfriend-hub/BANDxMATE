# Background chord-progression worker

This folder contains `chord_worker.py` — a Python script that runs forever on
your GCP VM, evolving chord progressions by complexity + novelty fitness and
writing the top-scoring set to `progressions.json`.

The HTML app fetches that JSON on every page load and merges it into its
progression memory, so the band actively plays what this worker has
discovered. The longer the worker runs, the wider and weirder the
progression pool becomes.

## What the worker is

- **Not a neural net.** It's a genetic-algorithm style evolver with a
  hand-coded fitness function that rewards harmonic variety, big harmonic
  distance between chords, use of rare qualities (quartal, min11, dim,
  aug, lydian, dom9), and actively *penalises* clichéd progressions like
  I-V-vi-IV and ii-V-I. The band will still cadence — the worker isn't
  throwing musicality away — it's just refusing to reward the obvious.
- **Cheap.** Runs on CPU, uses ~50 MB of RAM. No GPU needed.
- **Idempotent.** Save, stop, restart any time. It picks up the existing
  `progressions.json` and keeps evolving.

---

## Option A — quickest: run on your existing toposim VM

This runs the worker alongside toposim without conflict. Python's venv
keeps their packages isolated. The worker writes to a file; nothing in
toposim touches it.

### 1. SSH to the VM and set it up

Copy-paste this whole block:

```bash
# Get the worker onto the VM (either scp from your laptop or git clone)
mkdir -p ~/bandx && cd ~/bandx
# If the repo is cloned already, copy from there:
#   cp ~/BANDxMATE/cloud/chord_worker.py .
# Otherwise download directly from your fork/branch, e.g.:
#   curl -O https://raw.githubusercontent.com/YOURUSER/BANDxMATE/main/cloud/chord_worker.py

# Fresh venv so it can't break toposim
python3 -m venv venv
source venv/bin/activate
# Worker has zero dependencies — only uses the Python stdlib
pip install --upgrade pip

# Pick where to write output. If you'll serve it via nginx (Option 1 below),
# write straight to /var/www/html:
sudo mkdir -p /var/www/bandx
sudo chown -R $USER /var/www/bandx
export BANDX_OUT=/var/www/bandx/progressions.json
```

### 2. Make it a systemd service (runs forever, auto-restarts)

```bash
sudo tee /etc/systemd/system/bandx-worker.service >/dev/null <<EOF
[Unit]
Description=BANDxMATE chord-progression evolver
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/bandx
Environment="BANDX_OUT=/var/www/bandx/progressions.json"
Environment="BANDX_SAVE_EVERY=10"
Environment="BANDX_POPULATION=48"
Environment="BANDX_LIBRARY_SIZE=96"
ExecStart=$HOME/bandx/venv/bin/python $HOME/bandx/chord_worker.py
Restart=always
RestartSec=5
Nice=10
# Limit memory so toposim can never be killed by this:
MemoryMax=256M
CPUQuota=30%

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bandx-worker
sudo systemctl status bandx-worker --no-pager
```

You should see `active (running)` and within ~10 seconds
`/var/www/bandx/progressions.json` will exist.

Check the log any time:

```bash
journalctl -u bandx-worker -f
```

### 3. Serve the JSON so the HTML app can fetch it

The file is written but the browser needs to reach it. Two easy options:

#### Option 1: nginx on the same VM

```bash
sudo apt-get install -y nginx
sudo tee /etc/nginx/sites-available/bandx >/dev/null <<'EOF'
server {
    listen 80;
    root /var/www/bandx;
    # CORS so the HTML (served from anywhere) can fetch this:
    add_header Access-Control-Allow-Origin "*" always;
    add_header Cache-Control "no-store" always;
    location / {
        try_files $uri =404;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/bandx /etc/nginx/sites-enabled/bandx
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

# Open the firewall on GCP:
gcloud compute firewall-rules create allow-bandx-http \
    --allow tcp:80 --target-tags=http-server || true
gcloud compute instances add-tags $(hostname) \
    --tags http-server --zone=$(gcloud config get-value compute/zone)
```

Then in the HTML app open devtools → console once and run:

```js
localStorage.setItem('bandx.cloudUrl', 'http://YOUR_VM_EXTERNAL_IP/progressions.json');
location.reload();
```

Find your VM's external IP on the GCP Compute Engine console or with
`curl ifconfig.me` from inside the VM.

#### Option 2: Google Cloud Storage bucket (if you'd rather not open a port)

```bash
# One-time bucket setup
BUCKET=bandx-progressions-$(date +%s)
gsutil mb gs://$BUCKET
gsutil iam ch allUsers:objectViewer gs://$BUCKET

# Tell the bucket to allow CORS from anywhere (the HTML does the fetch)
cat > /tmp/cors.json <<'EOF'
[{"origin":["*"],"method":["GET"],"maxAgeSeconds":60}]
EOF
gsutil cors set /tmp/cors.json gs://$BUCKET

# Change the worker env to upload after each save.
# Edit the service:
sudo systemctl edit bandx-worker
# Paste:
#   [Service]
#   Environment="BANDX_OUT=/tmp/progressions.json"
#   ExecStartPost=/snap/bin/gsutil cp /tmp/progressions.json gs://BUCKETNAME/progressions.json
# Save, exit, then:
sudo systemctl restart bandx-worker
```

Then in the HTML app:

```js
localStorage.setItem('bandx.cloudUrl', 'https://storage.googleapis.com/BUCKETNAME/progressions.json');
location.reload();
```

---

## Option B — run it on your laptop as a test

```bash
cd cloud
python3 chord_worker.py
# ...wait 30 seconds, Ctrl+C...
cat progressions.json | head -40
```

You'll see 96 progressions sorted by complexity score. Some will be
normal-sounding, many will be weirdly good in ways a human wouldn't write.
That's the point.

---

## Config knobs

All via env vars (set them in the systemd unit):

| var                    | default | meaning                                                         |
| ---------------------- | ------- | --------------------------------------------------------------- |
| `BANDX_OUT`            | `./progressions.json` | path to write the JSON to                      |
| `BANDX_SAVE_EVERY`     | `10`    | seconds between saves                                           |
| `BANDX_POPULATION`     | `48`    | candidate progressions spawned per generation                   |
| `BANDX_LIBRARY_SIZE`   | `96`    | max progressions retained                                       |

Lower `SAVE_EVERY` for faster experiments, bump `POPULATION` if you want
the search to explore more per generation (uses more CPU).

---

## How complexity is scored

From `chord_worker.py: sequence_complexity`:

- **Variety** — unique chord qualities / length (0-1)
- **Avg harmonic jump** — Jaccard distance between adjacent chords'
  interval sets plus fm-consonance difference (0-1)
- **Rare-chord bonus** — fraction of the sequence using quartal, min11,
  dim, aug, lydian, dom9 (0-1)
- **Resolution** — how close the last chord sits to the first (0-1)
- **Cliché penalty** — -0.5 per 3-4 chord window that matches a known
  cliché (I-IV-V-I, ii-V-I, I-V-vi-IV, vi-IV-I-V, etc.)

Weighted roughly: 0.25 variety + 0.30 jump + 0.20 rare + 0.15 resolution
minus clichés. The HTML then normalises to 0-1 before merging.

---

## Live improv vs cloud training

Deep-training mode (this worker) *always* favours novelty. Live playback
in the browser has a `complexityWeight` that scales with `chaos` — at low
chaos the band leans into known good progressions (including cloud-
discovered), at high chaos it picks wilder moves. You don't need to do
anything to get this — it's automatic based on the chaos slider.

---

## To stop the worker

```bash
sudo systemctl stop bandx-worker
sudo systemctl disable bandx-worker
# optional: delete it
sudo rm /etc/systemd/system/bandx-worker.service
sudo systemctl daemon-reload
```
