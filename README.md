<p align="center">
<img src="https://raw.githubusercontent.com/isaksamsten/sia.nvim/refs/heads/main/assets/logo.png?raw=true" alt="Logo" width="200px">
</p>
<h1 align="center">sia.nvim</h1>

An LLM assistant for Neovim.

Supports: OpenAI, Copilot and OpenRouter (both OpenAI Chat Completions and Responses), Anthropic (native API), Gemini and ZAI.

## Features

https://github.com/user-attachments/assets/ac11de80-9979-4f30-803f-7ad79991dd13

https://github.com/user-attachments/assets/48cb1bb6-633b-412c-b33c-ae0b6792a485

https://github.com/user-attachments/assets/af327b9d-bbe1-47d6-8489-c8175a090a70

https://github.com/user-attachments/assets/ea037896-89fd-4660-85b6-b058423be2f6

- **Multiple interaction modes** — [chat, insert, and diff](docs/usage.md#interaction-modes) for different workflows
- **Comprehensive tool system** — [file operations, code search, shell access, LSP, and more](docs/tools.md)
- **Flexible approval system** — [blocking or async tool approval](docs/concepts.md#tool-approval-system) with customizable notifications
- **Change review** — [inline diff with accept/reject](docs/changes.md) for AI-suggested edits
- **Agent system** — [custom autonomous agents](docs/concepts.md#custom-agent-registry) for specialized tasks
- **Project-level config** — [per-project models, permissions, and risk levels](docs/configuration.md#project-level-configuration)
- **Persistent memory** — [agent memory](docs/concepts.md#agent-memory) and [conversation history](docs/concepts.md#conversation-history) across sessions
- **Cost tracking** — [real-time token usage and cost monitoring](docs/configuration.md#cost-tracking)

## Requirements

- Neovim >= **0.11**
- curl
- Access to OpenAI API, Copilot or Gemini

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

1. Set up [authentication](docs/authentication.md) for your provider.

2. Use `:Sia` to start a conversation:

   ```vim
   :Sia explain this codebase
   ```

3. Use `:Sia!` with a selection to get inline diffs:

   ```vim
   :'<,'>Sia! refactor this function
   ```

4. Navigate changes with `]c`/`[c`, accept with `ga`, reject with `gx`.

## Documentation

| Document | Description |
|----------|-------------|
| [Authentication](docs/authentication.md) | Setting up API keys and provider auth |
| [Configuration](docs/configuration.md) | Global settings, project config, permissions, risk levels |
| [Usage](docs/usage.md) | Interaction modes, commands, keybindings |
| [Tools](docs/tools.md) | Available tools for the AI assistant |
| [Core Concepts](docs/concepts.md) | Approval system, memory, todos, history, agents |
| [Reviewing Changes](docs/changes.md) | Inline diff workflow for accepting/rejecting edits |
| [Actions](docs/actions.md) | Built-in actions and creating custom actions |

