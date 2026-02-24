# Authentication

Sia supports multiple LLM providers. Set up authentication for the provider(s)
you want to use.

## OpenAI

[Get an OpenAI API
key](https://platform.openai.com/docs/api-reference/introduction) and add it to
your environment:

```bash
export OPENAI_API_KEY="sk-..."
```

### Codex (ChatGPT Pro/Plus)

Sia authenticates with Codex using your browser. Run the following command in
Neovim:

```vim
:SiaAuth codex
```

This will:

1. Open your browser to the OpenAI authorization page
2. After login, redirect back to the local server to complete the flow

The token is cached in `~/.cache/nvim/sia/` and automatically refreshed when it
expires. You only need to run `:SiaAuth codex` once.

**Note:** Requires a ChatGPT Pro or Plus subscription.

## GitHub Copilot

Sia authenticates with GitHub Copilot using the GitHub device flow. Run the
following command in Neovim:

```vim
:SiaAuth copilot
```

This will:

1. Open your browser to GitHub's device authorization page
2. Display a one-time code to enter in the browser
3. After authorization, cache the OAuth token locally

The token is cached in `~/.cache/nvim/sia/` and reused across sessions. You
only need to run `:SiaAuth copilot` once (or again if the token expires).

**Note:** Sia uses the official GitHub Copilot App for authentication, which
gives access to all available Copilot models (Claude, GPT-4.1, GPT-5, Gemini,
etc.). A GitHub Copilot subscription is required.

## Anthropic

Add your Anthropic API key to your environment:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

## Gemini

Add your Gemini API key to your environment:

```bash
export GEMINI_API_KEY="..."
```

## OpenRouter

Add your OpenRouter API key to your environment:

```bash
export OPENROUTER_API_KEY="sk-or-..."
```

## ZAI

Add your ZAI Coding API key to your environment:

```bash
export ZAI_CODING_API_KEY="..."
```

