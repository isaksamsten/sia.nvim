<p align="center">
<img src="https://raw.githubusercontent.com/isaksamsten/sia.nvim/refs/heads/main/assets/logo.png?raw=true" alt="Logo" width="200px">
</p>
<h1 align="center">sia.nvim</h1>

An LLM assistant for Neovim.

Supports: OpenAI, Codex, Copilot and OpenRouter (both OpenAI Chat Completions and Responses), Anthropic (native API), Gemini and ZAI.

## Features

https://github.com/user-attachments/assets/ac11de80-9979-4f30-803f-7ad79991dd13

https://github.com/user-attachments/assets/48cb1bb6-633b-412c-b33c-ae0b6792a485

https://github.com/user-attachments/assets/af327b9d-bbe1-47d6-8489-c8175a090a70

https://github.com/user-attachments/assets/ea037896-89fd-4660-85b6-b058423be2f6

- **Multiple interaction modes** — [chat, insert, and diff](docs/2-usage/1-modes.md) for different workflows
- **Comprehensive tool system** — [file operations, code search, shell access, LSP, and more](docs/5-features/4-tools.md)
- **Flexible approval system** — [blocking or async tool approval](docs/4-permissions/1-confirmation.md) with customizable notifications
- **Change review** — [inline diff with accept/reject](docs/2-usage/3-reviewing-changes.md) for AI-suggested edits
- **Agent system** — [custom autonomous agents](docs/5-features/2-agents.md) for specialized tasks
- **Project-level config** — [per-project models, permissions, and risk levels](docs/3-configuration/3-project.md)
- **Persistent memory** — [agent memory](docs/5-features/2-agents.md#agent-memory)
- **Cost tracking** — [real-time token usage and cost monitoring](docs/3-configuration/2-models.md#cost-tracking)

## Requirements

- Neovim >= **0.11**
- curl
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) — for the `grep` tool
- [fd](https://github.com/sharkdp/fd) — for the `glob` tool and directory listing
- Access to OpenAI API, Codex, Copilot, Gemini, Anthropic, ZAI, or OpenRouter
- Optional: [pandoc](https://pandoc.org/) — for the `fetch` tool (web content conversion)

## Installation

Install using Lazy:

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

## Quick Start

1. Set up [authentication](docs/1-getting-started.md#authentication) for your provider.

2. Use `:Sia` to start a conversation:

   ```vim
   :Sia explain this codebase
   ```

3. Use `:Sia!` with a selection to get inline changes:

   ```vim
   :'<,'>Sia! refactor this function
   ```

## Documentation

| Document | Description |
| ---------------------------------------- | --------------------------------------------------------- |
| [Getting Started](docs/1-getting-started.md) | Installation, authentication, first commands |
| [Modes](docs/2-usage/1-modes.md) | Chat, insert, and diff interaction modes |
| [Commands](docs/2-usage/2-commands.md) | Command reference |
| [Reviewing Changes](docs/2-usage/3-reviewing-changes.md) | Inline diff workflow for accepting/rejecting edits |
| [Keybindings](docs/2-usage/4-keybindings.md) | Suggested keybindings |
| [Settings](docs/3-configuration/1-settings.md) | Global settings and context management |
| [Models](docs/3-configuration/2-models.md) | Model definitions, providers, pricing |
| [Project Config](docs/3-configuration/3-project.md) | Per-project `.sia/config.json` reference |
| [Confirmation](docs/4-permissions/1-confirmation.md) | Blocking and async tool approval |
| [Permission Rules](docs/4-permissions/2-rules.md) | Allow/deny/ask rules and risk levels |
| [Actions](docs/5-features/1-actions.md) | Built-in and custom actions |
| [Agents](docs/5-features/2-agents.md) | Custom agents and memory |
| [Skills](docs/5-features/3-skills.md) | Reusable skill definitions |
| [Tools](docs/5-features/4-tools.md) | Available tools for the AI assistant |
| [Reference](docs/6-reference.md) | Highlight groups |
