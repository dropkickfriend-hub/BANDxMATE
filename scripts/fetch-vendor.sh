#!/usr/bin/env bash
# Download React / ReactDOM / Babel-standalone / Tailwind into www/vendor/ so
# the app runs fully offline inside the Capacitor wrapper.
# Run once on a machine with internet; re-run to update versions.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/www/vendor"
mkdir -p "$OUT"

REACT="https://cdnjs.cloudflare.com/ajax/libs/react/18.2.0/umd/react.production.min.js"
REACT_DOM="https://cdnjs.cloudflare.com/ajax/libs/react-dom/18.2.0/umd/react-dom.production.min.js"
BABEL="https://cdnjs.cloudflare.com/ajax/libs/babel-standalone/7.23.5/babel.min.js"
TAILWIND="https://cdn.tailwindcss.com/3.4.3"

dl(){ echo "  > $2"; curl -fsSL "$1" -o "$2"; }

dl "$REACT"     "$OUT/react.production.min.js"
dl "$REACT_DOM" "$OUT/react-dom.production.min.js"
dl "$BABEL"     "$OUT/babel.min.js"
dl "$TAILWIND"  "$OUT/tailwind.js"

echo "Vendor files in $OUT:"
ls -lh "$OUT"
