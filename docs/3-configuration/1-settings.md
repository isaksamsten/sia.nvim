# Settings

Configure Sia by calling `require("sia").setup()` in your `init.lua`. This page
covers global settings that apply to all conversations. For per-project
overrides, see [Project Configuration](3-project.md).

## Minimal Setup

```lua
require("sia").setup({
  settings = {
    model = "openai/gpt-4.1",
  },
})
```

## Full Settings Reference

```lua
require("sia").setup({
  settings = {
    -- Models
    model = "openai/gpt-4.1",                          -- Main conversational model
    fast_model = "openai/gpt-4.1-mini",                -- Fast model for quick tasks and compaction
    plan_model = "openai/o3-mini",                      -- Model for planning and reasoning
    embedding_model = "openai/text-embedding-3-small",  -- Model for semantic embeddings

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

    -- Tool call pruning (count-based)
    context = {
      max_tool = 200,                             -- Start pruning after this many tool calls
      exclude = { "grep", "glob", "read_todos" }, -- Tools that are never pruned
      clear_input = true,                         -- Clear tool input parameters during pruning
      keep = 20,                                  -- Recent tool calls to retain after pruning
    },

    -- Context window management (size-based)
    context_management = {
      prune_threshold = 0.85,     -- Start pruning at 85% of context window
      target_after_prune = 0.70,  -- Target 70% usage after pruning
      compact_ratio = 0.5,        -- Fraction of oldest messages to compact (last resort)
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

  -- Custom model definitions (see Models documentation)
  models = {},
})
```

## Context Management

Sia has two layers of context management that work together to keep
conversations within limits.

### Tool Call Pruning

Controlled by `context`, this prunes individual tool call results based on
count. When the number of tool calls exceeds **max_tool**, Sia removes the
oldest tool call results, keeping the most recent **keep** calls. Tools listed
in **exclude** are never pruned.

Set **clear_input** to also strip the tool input parameters (the arguments the
assistant sent), not just the results.

### Context Window Management

Controlled by `context_management`, this prevents conversations from exceeding
the model's context window. Sia estimates token usage by dividing the total byte
size of all messages by 4 (roughly 4 bytes per token for English text and code).

When estimated tokens exceed **prune_threshold** of the model's context window,
Sia applies increasingly aggressive strategies:

1. **Drop oldest tool call pairs** — removes the assistant's tool call message
   and the matching result message, starting from the oldest. Outdated messages
   (from cross-conversation invalidation) are dropped first. Tools in
   `context.exclude` are never dropped.

2. **Compact the conversation** (last resort) — summarizes the conversation
   history using `fast_model` and replaces old messages with the summary.

The chat winbar displays a context budget indicator when the model has a
`context_window` defined:

```
▰▱▱ 28% of 200K
```

The indicator changes color: normal below 85%, warning (`DiagnosticWarn`) at
85%+, error (`DiagnosticError`) at 95%+.

Compaction uses `fast_model` to generate summaries. Make sure your fast model
has a large enough context window (e.g., `openai/gpt-4.1-mini` with 1M tokens).

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
