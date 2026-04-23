# Background chord-progression worker

A Python script that runs forever on any Linux box with systemd + Python 3.7+.
It evolves chord progressions by complexity and novelty, and serves them on
port 8080 with CORS so the BANDxMATE HTML app can fetch them directly.

No nginx. No pip installs. No `gcloud` CLI required. One paste.

---

## One-line install (GCP VM, AWS, home server, whatever)

SSH into the VM. Paste this single line:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dropkickfriend-hub/BANDxMATE/main/cloud/install.sh)
```

The script:
1. Installs `python3` + `python3-venv` if missing (apt / dnf / yum all supported)
2. Writes the worker to `~/bandx/chord_worker.py`
3. Registers a systemd service (`bandx-worker`) that runs it forever and auto-restarts
4. Caps it at 256 MB / 30% CPU so it can't starve anything else (e.g. toposim)
5. Attempts to open port 8080 via `gcloud` if the CLI is present
6. Prints the exact `localStorage.setItem` line for the browser with your VM's IP filled in

After ~15 seconds you'll see a big summary box and a "paste this in the browser console" line. Do that, reload the band app, done.

**One manual step you'll probably have to do**: in the GCP web console, add the network tag `bandx` to your VM (VM instances → click your VM → Edit → Network tags → `bandx` → Save). If the installer could use `gcloud` it created the firewall rule for that tag, otherwise the final output tells you the web-console steps.

---

## If the `curl |` line fails (offline VM, private network, paranoid about piping to bash)

Save the installer to the VM some other way (scp, copy-paste it via the GCP console SSH's paste field, etc.) and run it directly:

```bash
bash ~/install.sh
```

The installer embeds the worker source inline — it doesn't fetch anything else.

If you want to inspect the installer before running it, it's `cloud/install.sh` in this repo. No network calls inside it.

---

## What it actually does

- Evolves chord progressions via mutation + crossover against a hand-coded fitness.
- Fitness rewards: variety, big harmonic jumps (tritone subs, chromatic mediants), rare chord qualities (quartal, min11, dim, aug, lydian, dom9), resolution back near the opening chord.
- Fitness *penalises*: I-IV-V-I, ii-V-I, I-vi-IV-V (50s doo-wop), I-V-vi-IV (Pachelbel / pop punk), vi-IV-I-V. −0.5 per matching cliché window.
- Not a neural net. Pure genetic algorithm. Runs on any CPU, ~50 MB RAM, zero deps beyond Python stdlib.

HTML side (already in `index.html`):
- On boot, `fetchCloudProgressions()` reads `localStorage.getItem('bandx.cloudUrl')` or falls back to a relative `progressions.json`.
- Merges entries into `progressionMemory.library` with their complexity scores.
- `structureEngine.nextChord` picks from the cloud-fed library with 60% preference when it has a match for the current context.

---

## Daily ops

```bash
sudo systemctl status bandx-worker        # is it running?
journalctl -u bandx-worker -f              # tail logs
sudo systemctl restart bandx-worker        # restart (e.g. after edit)
sudo systemctl stop bandx-worker           # stop
sudo systemctl disable --now bandx-worker  # stop and never restart
```

Tuning knobs (edit `/etc/systemd/system/bandx-worker.service`, then `sudo systemctl daemon-reload && sudo systemctl restart bandx-worker`):

| env var                | default | meaning                              |
| ---------------------- | ------- | ------------------------------------ |
| `BANDX_PORT`           | `8080`  | HTTP port                            |
| `BANDX_SAVE_EVERY`     | `10`    | seconds between file snapshots       |
| `BANDX_POPULATION`     | `48`    | candidates spawned per generation    |
| `BANDX_LIBRARY_SIZE`   | `96`    | max retained progressions            |

---

## Troubleshooting

**"curl failed"** — see above, scp the installer directly and run it.

**"sudo systemctl status bandx-worker shows failed"**
```bash
journalctl -u bandx-worker -n 50 --no-pager
```
Usually this is either (a) port 8080 already taken by something else (change `BANDX_PORT`) or (b) python3 not on the `$PATH` where systemd looks (the unit hard-codes the venv path — if you moved `~/bandx/` it breaks; just rerun the installer).

**"browser says CORS error"** — the worker sends `Access-Control-Allow-Origin: *` on every response. If the browser still complains, the request never reached the worker. Most likely the firewall isn't open for port 8080 — add the `bandx` tag to your VM (GCP → VM → Edit → Network tags → `bandx`). If you named the rule differently or want all-instances scope, set up the firewall rule manually in GCP → VPC network → Firewall.

**"localStorage.setItem complains"** — you're not on the band app's page. Open the BANDxMATE page first, *then* open devtools, *then* paste.

**"worker ran fine for a while but now the band isn't using new progressions"** — the HTML merges cloud progressions once per page load. Reload the app to pull the latest.

**"I want to see what the worker has discovered right now"**
```bash
curl -fsS http://127.0.0.1:8080/progressions.json | head -40
```

---

## HTTPS (optional, if you serve the HTML from https://)

Browsers block mixed content — an https page can't fetch from http. If your BANDxMATE page is served from https, you need https for the worker too. Easiest:

- **Cloudflare Tunnel**: `cloudflared tunnel run` gives you an https hostname that forwards to `localhost:8080`. Works behind firewalls.
- **Caddy reverse proxy**: `sudo apt install caddy`, single-line `Caddyfile` pointing at `127.0.0.1:8080` with auto Let's Encrypt.

Both are outside the scope of this installer. If you're running the HTML locally (file:// or http://localhost/) you don't need any of this.

---

## Uninstall

```bash
sudo systemctl disable --now bandx-worker
sudo rm /etc/systemd/system/bandx-worker.service
sudo systemctl daemon-reload
rm -rf ~/bandx
```

And in the browser:
```js
localStorage.removeItem('bandx.cloudUrl');
```
