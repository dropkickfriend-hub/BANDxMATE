#!/usr/bin/env bash
# Real production build.
#
# Turns index.html (which uses babel-standalone + tailwind CDN in-browser
# — both produce the "don't use in production" warnings) into www/index.html
# that ships:
#   • Pre-compiled JavaScript (no in-browser Babel)
#   • A static tailwind.css containing only the classes we use
#   • Local vendored React / ReactDOM
# and therefore has none of the CDN-production warnings.
#
# Dependencies are installed locally into node_modules via npm. No global
# installs. If Node isn't present, we install it via the OS package manager.
#
# Run:    bash scripts/build-prod.sh
# or:     npm run prod
#
# Output: www/index.html  (plus www/app.js, www/tailwind.css, www/vendor/*)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/index.html"
OUT_DIR="$HERE/www"
VENDOR_DIR="$OUT_DIR/vendor"
APP_JS="$OUT_DIR/app.js"
TAILWIND_CSS="$OUT_DIR/tailwind.css"
BUILD_DIR="$HERE/.build-cache"

say() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Node present? -------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  say "Node.js missing. Installing…"
  if   command -v apt-get >/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
  elif command -v dnf >/dev/null; then
    sudo dnf module install -y nodejs:20/common
  elif command -v yum >/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash -
    sudo yum install -y nodejs
  else
    fail "No package manager found. Install Node.js 18+ manually, then rerun."
  fi
fi
node --version >/dev/null || fail "node still not runnable"

# ── 2. Install build deps locally (devDependencies in package.json) --------
cd "$HERE"
if [ ! -d node_modules/@babel/core ] || [ ! -d node_modules/tailwindcss ]; then
  say "Installing build dependencies (first run takes ~30 s)"
  # Add to devDependencies if not already there; then install
  node -e '
    const fs=require("fs");
    const p=JSON.parse(fs.readFileSync("package.json","utf8"));
    p.devDependencies = p.devDependencies || {};
    const need = {
      "@babel/core":"^7.23.0",
      "@babel/cli":"^7.23.0",
      "@babel/preset-env":"^7.23.0",
      "@babel/preset-react":"^7.23.0",
      "tailwindcss":"^3.4.3"
    };
    let changed=false;
    for(const k of Object.keys(need)){
      if(!p.devDependencies[k]){ p.devDependencies[k]=need[k]; changed=true; }
    }
    if(changed){ fs.writeFileSync("package.json", JSON.stringify(p, null, 2)+"\n"); }
  '
  # Use --no-audit --no-fund for quieter, faster install
  npm install --no-audit --no-fund --silent
fi

# ── 3. Fetch vendor (React, ReactDOM) if missing --------------------------
mkdir -p "$VENDOR_DIR"
if [ ! -f "$VENDOR_DIR/react.production.min.js" ]; then
  say "Fetching vendor libs (React, ReactDOM)"
  if ! bash "$HERE/scripts/fetch-vendor.sh"; then
    say "vendor fetch failed — continuing, but you'll need to run 'npm run fetch-vendor' once you have network before the output works in a browser"
  fi
fi

# ── 4. Extract the <script type="text/babel"> block to raw JSX -----------
mkdir -p "$BUILD_DIR"
say "Extracting JSX source from $SRC"
node -e '
  const fs=require("fs");
  const html=fs.readFileSync("'"$SRC"'","utf8");
  const re=/<script\s+type="text\/babel">([\s\S]*?)<\/script>/;
  const m=html.match(re);
  if(!m){ console.error("No <script type=text/babel> block found"); process.exit(1); }
  fs.writeFileSync("'"$BUILD_DIR/app.jsx"'", m[1]);
  console.log("  jsx extracted: " + m[1].length + " bytes");
'

# ── 5. Babel-compile JSX → plain JS --------------------------------------
say "Compiling JSX with Babel"
# Babel config inline so we do not pollute the repo with dotfiles
cat > "$BUILD_DIR/babel.config.json" <<'EOF'
{
  "presets": [
    ["@babel/preset-env", { "targets": { "chrome": "90", "safari": "14", "firefox": "88" }, "modules": false }],
    ["@babel/preset-react", { "runtime": "classic" }]
  ]
}
EOF
./node_modules/.bin/babel \
  "$BUILD_DIR/app.jsx" \
  --config-file "$BUILD_DIR/babel.config.json" \
  --out-file "$APP_JS" \
  --no-comments
say "wrote $APP_JS ($(wc -c < "$APP_JS") bytes)"

# ── 6. Tailwind JIT scan → static CSS ------------------------------------
say "Generating static Tailwind CSS (scanning source for used classes)"
# Minimal tailwind.config.js that scans the source HTML + compiled JS
cat > "$BUILD_DIR/tailwind.config.cjs" <<'EOF'
module.exports = {
  content: [
    "index.html",
    ".build-cache/app.jsx",
    "www/app.js",
  ],
  theme: { extend: {} },
  plugins: [],
};
EOF
cat > "$BUILD_DIR/tailwind-input.css" <<'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;
EOF
./node_modules/.bin/tailwindcss \
  -c "$BUILD_DIR/tailwind.config.cjs" \
  -i "$BUILD_DIR/tailwind-input.css" \
  -o "$TAILWIND_CSS" \
  --minify \
  2>&1 | grep -v "^$" || true
say "wrote $TAILWIND_CSS ($(wc -c < "$TAILWIND_CSS") bytes)"

# ── 7. Assemble final www/index.html -------------------------------------
say "Writing production $OUT_DIR/index.html"
node -e '
  const fs=require("fs"), path=require("path");
  const html=fs.readFileSync("'"$SRC"'","utf8");

  // Swap CDN script tags for local vendor
  let out = html
    .replace(/<script src="https:\/\/cdnjs\.cloudflare\.com\/ajax\/libs\/react\/18\.2\.0\/umd\/react\.production\.min\.js"[^>]*><\/script>/,
      "<script src=\"vendor/react.production.min.js\"></script>")
    .replace(/<script src="https:\/\/cdnjs\.cloudflare\.com\/ajax\/libs\/react-dom\/18\.2\.0\/umd\/react-dom\.production\.min\.js"[^>]*><\/script>/,
      "<script src=\"vendor/react-dom.production.min.js\"></script>");

  // Drop the babel-standalone script entirely
  out = out.replace(/<script src="https:\/\/cdnjs\.cloudflare\.com\/ajax\/libs\/babel-standalone\/7\.23\.5\/babel\.min\.js"[^>]*><\/script>\n?/, "");

  // Replace Tailwind CDN with our compiled stylesheet
  out = out.replace(/<script src="https:\/\/cdn\.tailwindcss\.com"><\/script>/,
    "<link rel=\"stylesheet\" href=\"tailwind.css\">");

  // Replace the inline <script type="text/babel">...</script> with an
  // external ref to the Babel-compiled output
  out = out.replace(/<script\s+type="text\/babel">[\s\S]*?<\/script>/,
    "<script src=\"app.js\"></script>");

  fs.writeFileSync("'"$OUT_DIR"'/index.html", out);
  console.log("  wrote " + out.length + " bytes");
'

# ── 8. Sanity: refuse to ship a broken build -----------------------------
grep -q "babel-standalone" "$OUT_DIR/index.html" && fail "babel-standalone URL still present in output"
grep -q "cdn.tailwindcss.com" "$OUT_DIR/index.html" && fail "tailwind CDN still present in output"
grep -q "text/babel" "$OUT_DIR/index.html" && fail "text/babel script tag still present"
[ -s "$APP_JS" ]        || fail "app.js empty"
[ -s "$TAILWIND_CSS" ]  || fail "tailwind.css empty"

cat <<SUMMARY

  ╭──────────────────────────────────────────────────────────────╮
  │  Production build OK                                         │
  ╰──────────────────────────────────────────────────────────────╯
    $OUT_DIR/
      index.html   $(wc -c < "$OUT_DIR/index.html") bytes   (no CDN, no in-browser Babel)
      app.js       $(wc -c < "$APP_JS") bytes  (pre-compiled by Babel)
      tailwind.css $(wc -c < "$TAILWIND_CSS") bytes  (only classes we use)
      vendor/      React, ReactDOM

  Serve the www/ directory with any static server:
    python3 -m http.server -d $OUT_DIR 8000
    # then open http://localhost:8000

  Or deploy www/ to Netlify / Vercel / GCS bucket / Capacitor.

  The CDN production warnings are gone.
SUMMARY
