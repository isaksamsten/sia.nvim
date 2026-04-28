# Getting Started

## Requirements

- Neovim >= **0.11**
- curl
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for code search
- [fd](https://github.com/sharkdp/fd) for file finding and directory listing
- Access to at least one LLM provider (OpenAI, DeepSeek, Copilot, Anthropic, Gemini, OpenRouter, Codex, or ZAI)

## Installation

Install with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "isaksamsten/sia.nvim",
  opts = {},
  dependencies = {
    {
      "rickhowe/diffchar.vim",
      keys = {
        { "[z", "<Plug>JumpDiffCharPrevStart", desc = "Previous diff", silent = true },
        { "]z", "<Plug>JumpDiffCharNextStart", desc = "Next diff", silent = true },
        { "do", "<Plug>GetDiffCharPair", desc = "Obtain diff", silent = true },
        { "dp", "<Plug>PutDiffCharPair", desc = "Put diff", silent = true },
      },
    },
  },
}
```

## Authentication

Set up credentials for the provider(s) you want to use.

### OpenAI

[Get an API key](https://platform.openai.com/docs/api-reference/introduction)
and export it:

```bash
export OPENAI_API_KEY="sk-..."
```

### Codex (ChatGPT Pro/Plus)

Authenticate through your browser by running:

```vim
:SiaAuth codex
```

This opens the OpenAI authorization page. After you sign in, the token is cached
in `~/.cache/nvim/sia/` and refreshed automatically. You only need to do this
once.

Requires a ChatGPT Pro or Plus subscription.

### GitHub Copilot

Authenticate using the GitHub device flow:

```vim
:SiaAuth copilot
```

This opens GitHub's device authorization page and displays a one-time code to
enter in the browser. The token is cached in `~/.cache/nvim/sia/` and reused
across sessions.

Sia uses the official GitHub Copilot App, which gives access to all available
Copilot models (Claude, GPT, Gemini, etc.). Requires a GitHub Copilot
subscription.

### DeepSeek

```bash
export DEEPSEEK_API_KEY="sk-..."
```

### Anthropic

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Gemini

```bash
export GEMINI_API_KEY="..."
```

### OpenRouter

```bash
export OPENROUTER_API_KEY="sk-or-..."
```

### ZAI

```bash
export ZAI_CODING_API_KEY="..."
```

## Discover Available Models

Sia ships with a set of seed models for each provider, but you can fetch the
full list of models available to your account by running:

```vim
:SiaModel refresh
```

Results are cached across sessions. Use `:SiaModel list` to see all available
models, or `:SiaModel list openai` to filter by provider.

## First Commands

Open any file and try these:

```vim
" Open a chat conversation
:Sia explain this codebase

" Generate code at your cursor
:Sia! write a fibonacci function

" Refactor selected code (visual select first, then run)
:'<,'>Sia! simplify this function
```

## Three Interaction Modes

Sia has three modes that determine how the assistant responds.

**Chat** — `:Sia [query]` opens a persistent conversation. The assistant can
read files, search code, run commands, and explain its reasoning. Use this for
exploration, multi-step problem solving, and code review.

**Insert** — `:Sia! [query]` (without a range) generates text and inserts it
directly at the cursor. Use this for code generation, boilerplate, and
documentation.

**Diff** — `:'<,'>Sia! [query]` (with a range) shows the assistant's suggested
changes in an inline diff. You navigate changes with `]c`/`[c` and accept or
reject them individually. Use this for refactoring and targeted edits.

See [Modes](2-usage/1-modes.md) for a detailed guide on each mode.
