#!/usr/bin/env bash
# Validate every mermaid diagram in the docs. CI runs exactly this.
#
# Parsing with the real library rather than pattern matching, because a regex that looks for
# unbalanced quotes passes on things GitHub will refuse to draw.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

command -v node >/dev/null || { echo "node not on PATH, skipping diagram validation"; exit 0; }
# installed into the repo so node resolves them from the script's own directory
npm install --silent --no-save --no-audit --no-fund mermaid jsdom >/dev/null 2>&1
node tests/parse-mermaid.mjs
