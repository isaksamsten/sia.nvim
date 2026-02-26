#!/usr/bin/env bash
# scripts/build-doc.sh
# Concatenates docs/ markdown files into a single file for panvimdoc,
# then runs panvimdoc to generate doc/sia.txt.
#
# Usage:
#   ./scripts/build-doc.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$PROJECT_DIR/docs"
COMBINED="$PROJECT_DIR/doc/sia.md"

mkdir -p "$PROJECT_DIR/doc"

# Build combined markdown in a defined order
{
  # Start with a top-level heading for the vimdoc title
  cat <<'HEADER'
# sia.nvim

An LLM assistant for Neovim.

Supports: OpenAI, Copilot and OpenRouter (both OpenAI Chat Completions and
Responses), Anthropic (native API), Gemini and ZAI.

For the latest version, see: https://github.com/isaksamsten/sia.nvim

HEADER

  for doc in \
    "$DOCS_DIR/authentication.md" \
    "$DOCS_DIR/configuration.md" \
    "$DOCS_DIR/usage.md" \
    "$DOCS_DIR/tools.md" \
    "$DOCS_DIR/concepts.md" \
    "$DOCS_DIR/changes.md" \
    "$DOCS_DIR/actions.md"; do

    if [[ -f "$doc" ]]; then
      echo ""
      # Strip any filename prefix from cross-file links, e.g.
      # [text](configuration.md#anchor) -> [text](#anchor)
      # [text](configuration.md)        -> [text](#configuration)  (no-anchor case)
      sed -E \
        -e 's|\(([a-zA-Z0-9_-]+)\.md#([^)]+)\)|(#\2)|g' \
        -e 's|\(([a-zA-Z0-9_-]+)\.md\)|(#\1)|g' \
        "$doc"
      echo ""
    else
      echo "Warning: $doc not found, skipping." >&2
    fi
  done
} > "$COMBINED"

echo "Generated $COMBINED"

