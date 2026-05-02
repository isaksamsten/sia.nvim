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
Responses), Anthropic (native API), Cerebras, Groq, Gemini and ZAI.

For the latest version, see: https://github.com/isaksamsten/sia.nvim

HEADER

  for doc in \
    "$DOCS_DIR/1-getting-started.md" \
    "$DOCS_DIR/2-usage/1-modes.md" \
    "$DOCS_DIR/2-usage/2-commands.md" \
    "$DOCS_DIR/2-usage/3-reviewing-changes.md" \
    "$DOCS_DIR/2-usage/4-keybindings.md" \
    "$DOCS_DIR/3-configuration/1-settings.md" \
    "$DOCS_DIR/3-configuration/2-models.md" \
    "$DOCS_DIR/3-configuration/3-project.md" \
    "$DOCS_DIR/4-permissions/1-confirmation.md" \
    "$DOCS_DIR/4-permissions/2-rules.md" \
    "$DOCS_DIR/5-features/1-actions.md" \
    "$DOCS_DIR/5-features/2-agents.md" \
    "$DOCS_DIR/5-features/3-skills.md" \
    "$DOCS_DIR/5-features/4-tools.md" \
    "$DOCS_DIR/6-reference.md" \
    "$DOCS_DIR/7-recipes/1-orchestrator.md"; do

    if [[ -f "$doc" ]]; then
      echo ""
      # Strip path prefixes from cross-file links, e.g.
      # [text](../3-configuration/1-settings.md#anchor) -> [text](#anchor)
      # [text](2-commands.md)                           -> [text](#commands)
      # [text](configuration.md#anchor)                 -> [text](#anchor)
      sed -E \
        -e 's|\((\.\./)*[0-9]+-[a-zA-Z]+/[0-9]+-([a-zA-Z0-9_-]+)\.md#([^)]+)\)|(#\3)|g' \
        -e 's|\((\.\./)*[0-9]+-[a-zA-Z]+/[0-9]+-([a-zA-Z0-9_-]+)\.md\)|(#\2)|g' \
        -e 's|\((\.\./)*[0-9]+-([a-zA-Z0-9_-]+)\.md#([^)]+)\)|(#\3)|g' \
        -e 's|\((\.\./)*[0-9]+-([a-zA-Z0-9_-]+)\.md\)|(#\2)|g' \
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

