#!/usr/bin/env bash
# Produce www/index.html from live_ai_band.html with CDN <script> tags rewritten
# to local vendor paths so the Capacitor-wrapped app has zero network deps.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/live_ai_band.html"
DST="$HERE/www/index.html"
mkdir -p "$HERE/www"

sed \
  -e 's|https://cdnjs.cloudflare.com/ajax/libs/react/18.2.0/umd/react.production.min.js|vendor/react.production.min.js|g' \
  -e 's|https://cdnjs.cloudflare.com/ajax/libs/react-dom/18.2.0/umd/react-dom.production.min.js|vendor/react-dom.production.min.js|g' \
  -e 's|https://cdnjs.cloudflare.com/ajax/libs/babel-standalone/7.23.5/babel.min.js|vendor/babel.min.js|g' \
  -e 's|https://cdn.tailwindcss.com|vendor/tailwind.js|g' \
  "$SRC" > "$DST"

echo "Wrote $DST ($(wc -c < "$DST") bytes)"
