# Settings

Configure Sia by calling `require("sia").setup()` in your `init.lua`. This page
covers global settings that apply to all conversations. For per-project
overrides, see [Project Configuration](3-project.md).

## Minimal Setup

```lua
require("sia").setup({
  settings = {
    model = "openai/gpt-5.2",
  },
})
```

## Full Settings Reference

```lua
require("sia").setup({
  settings = {
    -- Models
    model = "openai/gpt-5.2",                              -- Main conversational model
    fast_model = "openai/gpt-4.1",                          -- Fast model for quick tasks and compaction
    plan_model = "openai/gpt-5.2",                          -- Model for planning and reasoning

    -- Icon set: "emoji" or a custom table
    icons = "emoji",

    -- UI settings
    ui = {
      diff = {
        enable = true,        -- Enable the inline diff system
        show_signs = true,    -- Show signs in the gutter for changes
        char_diff = true,     -- Show character-level diffs
      },
      confirm = {
        use_vim_ui = false,   -- Use Vim's built-in input/select for confirmations
        show_preview = true,  -- Show detailed preview in confirm prompts
        async = {
          enable = false,     -- Enable non-blocking confirmation mode
          -- notifier = require("sia.ui.confirm").floating_notifier(),
        },
      },
    },

    -- File operations
    file_ops = {
      trash = true,                     -- Move deleted files to trash instead of removing
      create_dirs_on_rename = true,     -- Auto-create directories when renaming files
      restrict_to_project_root = true,  -- Restrict file operations to the project root
    },

    -- Shell configuration for the bash tool
    shell = {
      command = "/bin/bash",
      args = { "-s" },
      -- args can also be a function returning string[]
    },

    -- Globally enabled agents and skills
    agents = { "code/review", "code/explore" },
    skills = { "update-docs" },

    -- Context retention
    context = {
      tools = {
        max_calls = 200,                              -- Start pruning after this many tool calls
        preserve = { "grep", "glob", "read_todos" },  -- Tools that should never be pruned
        strip_inputs = true,                          -- Remove tool arguments from retained entries
        keep_last = 20,                               -- Keep the newest tool calls once pruning starts
      },
      tokens = {
        prune = {
          at_fraction = 0.85,  -- Start shrinking context at 85% of the model window
          to_fraction = 0.70,  -- Aim to get back down to 70%
        },
        compact = {
          oldest_fraction = 0.5, -- Fraction of the oldest history to summarize as a last resort
        },
        media = {
          max_bytes = 8 * 1024 * 1024, -- Keep image/document payloads under this many bytes
          keep_last = 1,               -- Always keep this many newest media payloads
        },
      },
    },

    -- Chat window defaults
    chat = {
      cmd = "botright vnew",
      wo = { wrap = true, spell = false },
      winbar = {
        left = function(data) return "" end,
        center = function(data) return "" end,
        right = function(data) return "" end,
      },
    },
  },

  -- Custom actions (see Actions documentation)
  actions = {},

  -- Custom provider overrides (see Models documentation)
  providers = {},

  -- Model option overrides by provider (see Models documentation)
  models = {},
})
```

Use `settings.agents` to make agent definitions available across all projects.
Store the agent files themselves in `~/.config/sia/agents/` when you want that
global behavior. A project can still override the enabled list in
`.sia/config.json`.

## Context Management

Sia keeps context under control with one `context` setting that is split into
two clear parts:

- `context.tools` handles pruning old tool calls.
- `context.tokens` handles the overall token budget for the conversation.

### Tool Call Pruning

Controlled by `context.tools`, this prunes individual tool call results based
on count. When the number of tool calls exceeds **max_calls**, Sia removes the
oldest tool call results, keeping the most recent **keep_last** calls. Tools
listed in **preserve** are never pruned.

Set **strip_inputs** to also remove the tool input parameters (the arguments
the assistant sent), not just the results.

### Context Window Management

Controlled by `context.tokens`, this prevents conversations from exceeding
the model's context window. Sia estimates token usage by dividing the total byte
size of all messages by 4 (roughly 4 bytes per token for English text and code).

When estimated tokens exceed **prune.at_fraction** of the model's context
window,
Sia applies increasingly aggressive strategies:

1. **Drop oldest tool call pairs** — removes the assistant's tool call message
   and the matching result message, starting from the oldest. Outdated messages
   (from cross-conversation invalidation) are dropped first. Tools in
   `context.tools.preserve` are never dropped.

2. **Compact the conversation** (last resort) — summarizes the conversation
   history using `fast_model` and replaces old messages with the summary.

`prune.to_fraction` controls how far Sia tries to shrink the conversation
before it stops. `compact.oldest_fraction` controls how much of the oldest
history is summarized when simple tool pruning is not enough.

Large image and document tool results are also managed under `context.tokens.media`.
Sia counts their base64 payloads in token estimates and replaces the oldest media
payloads with short text placeholders once the total media bytes exceed
`media.max_bytes`. `media.keep_last` keeps the newest media payloads available
for follow-up questions.

The chat winbar displays a context budget indicator when the model has a
`context_window` defined:

```
▰▱▱ 28% of 200K
```

The indicator changes color: normal below 85%, warning (`DiagnosticWarn`) at
85%+, error (`DiagnosticError`) at 95%+.

Compaction uses `fast_model` to generate summaries. Make sure your fast model
has a large enough context window (e.g., `openai/gpt-4.1` with 1M tokens).

### Winbar Customization

The winbar renders three sections: **left**, **center**, and **right**. Each is
a function that receives a `data` table with the current conversation state and
returns a string.

```lua
require("sia").setup({
  settings = {
    chat = {
      winbar = {
        left = function(data)
          -- Default: spinner + active bash/agents
          return ""
        end,
        center = function(data)
          -- Default: status messages
          return ""
        end,
        right = function(data)
          -- Default: token count display
          return ""
        end,
      },
    },
  },
})
```

Set `winbar` to `nil` to disable it entirely.
