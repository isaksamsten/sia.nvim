# Configuration

Sia can be customized both globally (in your Neovim config) and per-project
(using `.sia/config.json`).

## Global Configuration

Configure Sia in your `init.lua`:

```lua
require("sia").setup({
  settings = {
    model = "openai/gpt-4.1",           -- Main model for conversations
    fast_model = "openai/gpt-4.1-mini", -- Fast model for quick tasks
    plan_model = "openai/o3-mini",       -- Model for planning and reasoning
    embedding_model = "openai/text-embedding-3-small", -- Model for semantic embeddings
    temperature = 0.3,                   -- Creativity level (0-1)
    icons = "emoji",                     -- Icon set: "emoji" or a custom table

    -- UI behavior
    ui = {
      diff = {
        enable = true,       -- Enable diff system for change tracking
        show_signs = true,   -- Show signs in the gutter for changes
        char_diff = true,    -- Show character-level diffs
      },
      confirm = {
        use_vim_ui = false,  -- Use Vim's built-in input/select for confirm
        show_preview = true, -- Show preview in confirm prompts
        async = {
          enable = false,    -- Queue confirm in background (non-blocking)
          -- notifier = require("sia.ui.confirm").floating_notifier(), -- default
        },
      },
    },

    -- File operations
    file_ops = {
      trash = true,                      -- Move deleted files to trash
      create_dirs_on_rename = true,      -- Create directories when renaming
      restrict_to_project_root = true,   -- Restrict file operations to project
    },

    -- Default context settings
    context = {
      max_tool = 200,        -- Maximum tool calls before pruning occurs
      exclude = { "grep", "glob", "read_todos" }, -- Tool names to exclude from pruning
      clear_input = true,    -- Whether to clear tool input parameters during pruning
      keep = 20,             -- Number of recent tool calls to keep after pruning
    },

    -- Shell configuration for the bash tool
    shell = {
      command = "/bin/bash",
      args = { "-s" },
      -- args can be a function returning a string[]
      -- args = function()
      --   return { "-lc" }
      -- end,
    },

    -- Automatic context window management
    context_management = {
      prune_threshold = 0.85,    -- Start pruning at 85% of context window
      target_after_prune = 0.70, -- Target 70% after pruning
      compact_ratio = 0.5,       -- Fraction of messages to compact (last resort)
    },
  },

  -- Add custom actions (see Actions documentation)
  actions = {
    -- Your custom actions here
  }
})
```

## Cost Tracking

Sia provides real-time cost tracking and token usage monitoring in the chat
window's status bar (winbar). This helps you track API costs and token
consumption during conversations.

### Adding Pricing to Custom Models

For OpenRouter or other custom models, you can add pricing information to your
model configuration:

```lua
require("sia").setup({
  models = {
    ["openrouter/custom-model"] = {
      "openrouter",
      "provider/model-name",
      pricing = { input = 3.00, output = 15.00 },  -- Per 1M tokens in USD
      cache_multiplier = { read = 0.1, write = 1.25 }  -- Optional: cache pricing multipliers
    },
  }
})
```

**Cache pricing multipliers:**

- `read`: Multiplier for cached tokens read from cache
- `write`: Multiplier for cache creation tokens (only Anthropic is currently supported)

Providers with built-in cache multipliers (Anthropic, OpenAI) will
automatically apply these. For custom models, specify `cache_multiplier`
in the model configuration.

### Setting Context Window Size

All built-in models include a `context_window` parameter (in tokens) that tells
Sia the maximum context the model supports. If you define custom models, you
should set this so that Sia can track context usage and automatically manage
conversation length:

```lua
require("sia").setup({
  models = {
    ["openrouter/my-model"] = {
      "openrouter",
      "provider/model-name",
      context_window = 128000,  -- 128K tokens
    },
  }
})
```

When `context_window` is set, the winbar displays a context budget indicator
showing what percentage of the model's context window is currently in use.
This also enables automatic context management (see
[Context Window Management](concepts.md#context-window-management)).

If `context_window` is not set for a model, context tracking and automatic
pruning are disabled for that model — conversations will grow without limits.

The winbar is enabled by default in chat windows. You can customize or disable
it via the `settings.chat.winbar` option (set to `nil` to disable).

### Extended Thinking for Claude Models (Copilot)

Claude models accessed through the Copilot provider (e.g., `copilot/claude-sonnet-4.6`,
`copilot/claude-opus-4.6`) support **extended thinking**, which allows the model to
reason more deeply before responding. This is not enabled by default — you must
configure it in your project's `.sia/config.json`.

Extended thinking requires several parameters to work together:

| Parameter         | Description                                                    |
| ----------------- | -------------------------------------------------------------- |
| `thinking_budget` | Token budget for the model's internal reasoning (e.g., `4000`) |
| `thinking`        | Thinking mode configuration (e.g., `{ "type": "adaptive" }`)   |
| `max_tokens`      | Maximum output tokens — must be set when thinking is enabled   |
| `top_p`           | Sampling parameter — typically set to `1` with thinking        |
| `output_config`   | Output configuration (e.g., `{ "effort": "high" }`)            |

**Using `models` overrides** (recommended — applies to all conversations using
that model):

```json
{
  "models": {
    "copilot/claude-sonnet-4.6": {
      "max_tokens": 16000,
      "top_p": 1,
      "thinking_budget": 4000,
      "thinking": { "type": "adaptive" },
      "output_config": { "effort": "high" }
    }
  }
}
```

**Using `aliases`** (creates a separate model name you can switch to with
`:Sia -m`):

```json
{
  "aliases": {
    "sonnet-thinking": {
      "name": "copilot/claude-sonnet-4.6",
      "max_tokens": 16000,
      "top_p": 1,
      "thinking_budget": 8000,
      "thinking": { "type": "adaptive" },
      "output_config": { "effort": "high" }
    }
  }
}
```

Then use it with `:Sia -m sonnet-thinking your prompt here`.

**Using `model` override** (sets the project default model with thinking
enabled):

```json
{
  "model": {
    "name": "copilot/claude-sonnet-4.6",
    "max_tokens": 16000,
    "top_p": 1,
    "thinking_budget": 4000,
    "thinking": { "type": "adaptive" },
    "output_config": { "effort": "high" }
  }
}
```

> **Note**: The `thinking_budget` controls how many tokens the model can use for
> internal reasoning. Higher values allow deeper thinking but increase latency
> and token usage. The `"adaptive"` thinking type lets the model decide how much
> reasoning is needed for each request.

### Customizing Winbar Display

The winbar is rendered by calling three functions: `left`, `center`, and `right`. Each
function receives a `data` table with the current conversation state.

```lua
require("sia").setup({
  settings = {
    chat = {
      winbar = {
        left = function(data)
          -- Default: active spinner + bash + agents
          return ""
        end,
        center = function(data)
          -- Default: cost tracking progress bar
          return ""
        end,
        right = function(data)
          -- Default: token count display
          return ""
        end,
      }
    }
  }
})
```

## Project-Level Configuration

Create `.sia/config.json` in your project root to customize Sia for that
specific project:

```json
{
  "model": "copilot/gpt-5-mini",
  "fast_model": {
    "name": "openai/gpt-4.1-mini",
    "temperature": 0.1
  },
  "plan_model": "openai/o3-mini",
  "auto_continue": true,
  "action": {
    "insert": "custom_insert_action",
    "diff": "custom_diff_action",
    "chat": "custom_chat_action"
  },
  "context": {
    "max_tool": 50,
    "exclude": ["grep", "glob"],
    "clear_input": false,
    "keep": 10
  },
  "skills": ["monitor-logs", "tmux-interactive"],
  "skills_extras": ["~/my-custom-skills"],
  "permission": {
    "allow": {
      "bash": {
        "arguments": {
          "command": ["^git diff", "^git status$", "^uv build"]
        }
      },
      "edit": {
        "arguments": {
          "target_file": [".*%.lua$", ".*%.py$", ".*%.js$"]
        }
      }
    },
    "deny": {
      "bash": {
        "arguments": {
          "command": ["rm -rf", "sudo"]
        }
      },
      "remove_file": {
        "arguments": {
          "path": [".*important.*", ".*config.*"]
        }
      }
    },
    "ask": {
      "write": {
        "arguments": {
          "path": ["^(\\.md$)@!.*"]
        }
      }
    }
  },
  "risk": {
    "bash": {
      "arguments": {
        "command": [
          { "pattern": "^ls", "level": "safe" },
          { "pattern": "^cat", "level": "safe" },
          { "pattern": "rm", "level": "warn" }
        ]
      }
    }
  }
}
```

### Available Local Configuration Options

- **`model`**: Override the default model for this project. Can be specified as:
  - String: `"openai/gpt-4.1"` (uses default settings)
  - Object: `{ "name": "openai/gpt-4.1", "temperature": 0.7 }` (override model-specific parameters like temperature, pricing, or provider-specific options)
- **`fast_model` / `plan_model`**: Override the fast/plan models. Same format
  as `model`.
- **`models`**: Override parameters for specific models by name (e.g.,
  `{ "openai/gpt-5.1": { "reasoning_effort": "medium" } }`).
- **`aliases`**: Rename model with different parameters e.g.,
  `{ "codex-high": { "name": "codex/gpt-5.3-codex", "reasoning_effort": "high" }`
  and then use as `Sia -m codex-high ....`
- **`auto_continue`**: Automatically continue execution when tools are
  cancelled (default: false)
- **`action`**: Override default actions for different modes (`insert`, `diff`, `chat`)
- **`context`**: Project-specific context management (tool pruning behavior)
- **`skills`**: Array of skill names to enable from `~/.config/sia/skills/` or extra paths
  (e.g., `["monitor-logs", "tmux-interactive"]`). Skills are techniques the assistant
  knows for combining tools effectively.
- **`skills_extras`**: Array of additional directory paths to search for skill definitions
  (e.g., `["/path/to/custom/skills"]`). Each skill is a subdirectory containing a `SKILL.md` file.
- **`permission`**: Fine-grained tool access control (see [Permission System](#permission-system) below)
- **`risk`**: Configure risk levels for visual feedback and auto-confirm behavior (see [Risk Level System](#risk-level-system) below)

### Permission System

The permission system uses **Vim regex patterns** (with very magic mode `\v`)
to control tool access:

**Rule Precedence** (in order):

1. **Deny rules**: Block operations immediately without confirmation
2. **Ask rules**: Require user confirmation before proceeding
3. **Allow rules**: Auto-approve operations that match all configured patterns

**Rule Structure**:

- Each tool permission must have an `arguments` field
- `arguments`: Object mapping parameter names to pattern arrays
- `allow` entries may be either a single rule object or an array of rule objects
- `choice` (allow rules only): Auto-selection index for multi-choice prompts (default: 1)

**Pattern Format**:
Patterns are Vim regex strings using very magic mode (`\v`):

- Simple pattern strings: `"^git status$"`, `"^ls"`, `"\\.lua$"`
- Multiple patterns in an array are OR'd together: `["^git status", "^git diff", "^git log"]`
- Use negative lookahead for exclusions: `"^(rm|sudo)@!.*"` (matches anything NOT starting with rm or sudo)

**Pattern Matching**:

- Patterns use Vim regex syntax with `\v` (very magic mode)
- Multiple patterns in an array are OR'd together
- All configured argument patterns must match for the rule to apply
- `nil` arguments are treated as empty strings (`""`)
- Non-string arguments are converted to strings with `tostring()`
- See `:help vim.regex()` for full syntax details

#### Permission Examples

**Auto-approve safe git commands:**

```json
{
  "permission": {
    "allow": {
      "bash": {
        "arguments": {
          "command": ["^git status$", "^git diff", "^git log"]
        }
      }
    }
  }
}
```

**Persist approvals from opt-in tools:**

When an opt-in tool prompt is answered with `always`, Sia appends an allow rule to
`.sia/auto.json`. If a tool already has one allow rule, Sia promotes it to an array
so multiple persisted rules can coexist.

```json
{
  "permission": {
    "allow": {
      "view": [
        {
          "arguments": {
            "path": ["^lua/sia/[^/]+\\.lua$"]
          }
        },
        {
          "arguments": {
            "path": ["^tests/[^/]+\\.lua$"]
          }
        }
      ]
    }
  }
}
```

**Restrict file operations to source code:**

```json
{
  "permission": {
    "allow": {
      "edit": {
        "arguments": {
          "target_file": ["src/.*\\.(js|ts|py)$"]
        }
      }
    },
    "deny": {
      "remove_file": {
        "arguments": {
          "path": [".*\\.(config|env)"]
        }
      }
    }
  }
}
```

This system provides fine-grained control over AI assistant capabilities while
maintaining security and preventing accidental destructive operations.

### Risk Level System

The risk level system provides visual feedback and control over how tool operations
are presented in the async confirm UI. Unlike the permission system (which controls whether
operations require confirmation), the risk system lets you mark operations as safe,
informational, or risky. By default, the risk system is used together with the
async approval system to highlight tools differently.

**Risk Levels:**

1. **`safe`** - Low-risk operations (by default, displayed with `SiaApproveSafe` highlight)
2. **`info`** - Standard operations (by default, displayed with `SiaApproveInfo` highlight)
3. **`warn`** - High-risk operations (by default, displayed with `SiaApproveWarn` highlight)

**How it works:**

- Each tool has a default risk level (usually `"info"`)
- Your `risk` config can escalate or de-escalate operations based on patterns
- Multiple matching patterns → highest risk level wins
- Auto-confirm only applies when resolved risk level ≤ `info`

**Configuration format:**

```json
{
  "risk": {
    "tool_name": {
      "arguments": {
        "parameter_name": [
          { "pattern": "vim_regex_pattern", "level": "safe|info|warn" }
        ]
      }
    }
  }
}
```

#### Risk Level Examples

**Highlight safe commands:**

```json
{
  "risk": {
    "bash": {
      "arguments": {
        "command": [
          { "pattern": "^ls", "level": "safe" },
          { "pattern": "^cat", "level": "safe" },
          { "pattern": "^echo", "level": "safe" },
          { "pattern": "^git status", "level": "safe" },
          { "pattern": "^git diff", "level": "safe" }
        ]
      }
    }
  }
}
```

**Highlight dangerous commands:**

```json
{
  "risk": {
    "bash": {
      "arguments": {
        "command": [{ "pattern": "\\brm\\b", "level": "warn" }]
      }
    },
    "remove_file": {
      "arguments": {
        "path": [{ "pattern": "\\.(env|config)$", "level": "warn" }]
      }
    }
  }
}
```

### Context Management

Sia has two layers of context management that work together:

**Tool call pruning** (`context`): Controls how individual tool call results
are pruned within a conversation based on count:

- **Tool pruning**: Use `context.max_tool` to set when pruning occurs and
  `context.keep` to control how many recent tool calls are retained
- **Pruning exclusions**: Use `context.exclude` to specify tool names that
  should never be pruned (e.g., `["grep", "glob"]`)
- **Input parameter clearing**: Use `context.clear_input` to also remove tool
  input parameters during pruning

**Context window management** (`context_management`): Automatically prevents
conversations from exceeding the model's context window. See
[Context Window Management](concepts.md#context-window-management) for details
on how this works. Configure the thresholds:

- **`prune_threshold`** (default: `0.85`): Start pruning when estimated tokens
  reach this fraction of the context window
- **`target_after_prune`** (default: `0.70`): Target this fraction after pruning
- **`compact_ratio`** (default: `0.5`): Fraction of oldest messages to include
  when compacting (last resort)

> **Note**: Compaction uses `fast_model` to generate summaries. Ensure your
> `fast_model` has a sufficiently large context window (e.g., `openai/gpt-4.1-mini`
> with 1M tokens) to accommodate the messages being summarized.

### Auto-Continue Behavior

When a user cancels a tool operation, Sia normally asks "Continue?
(Y/n/[a]lways)". Setting `auto_continue: true` bypasses this prompt and
automatically continues execution. This is useful for automated workflows where
you want the AI to keep working even if individual operations are cancelled.

### Custom Default Actions

The `action` configuration allows you to override the default actions for different interaction modes:

- **`insert`**: Action used when calling `:Sia!` (insert mode)
- **`diff`**: Action used when calling `:Sia!` with a range (diff mode)
- **`chat`**: Action used when calling `:Sia` (chat mode)

Each field should reference an action name defined in your global configuration. This allows you to customize the behavior, system prompts, tools, and models used for different types of interactions on a per-project basis.

**Example**: Use a specialized action for writing in a specific project:

```json
{
  "action": {
    "chat": "prose"
  }
}
```

## Highlight Groups

Sia defines the following highlight groups that you can customize. They are
only set if they don't already exist, so defining them in your colorscheme
or config will take precedence.

**Change Review (inline diff):**

| Group                 | Default Link           | Description               |
| --------------------- | ---------------------- | ------------------------- |
| `SiaDiffAdd`          | `DiffAdd`              | Added lines               |
| `SiaDiffChange`       | `DiffChange`           | Changed lines             |
| `SiaDiffDelete`       | `DiffDelete`           | Deleted lines             |
| `SiaDiffInlineAdd`    | `GitSignsAddInline`    | Character-level additions |
| `SiaDiffInlineChange` | `GitSignsChangeInline` | Character-level changes   |
| `SiaDiffAddSign`      | `GitSignsAdd`          | Sign column for additions |
| `SiaDiffChangeSign`   | `GitSignsChange`       | Sign column for changes   |

**Chat UI:**

| Group           | Default Link | Description               |
| --------------- | ------------ | ------------------------- |
| `SiaAssistant`  | `DiffAdd`    | Assistant message markers |
| `SiaUser`       | `DiffChange` | User message markers      |
| `SiaToolResult` | `DiffChange` | Tool result markers       |
| `SiaProgress`   | `NonText`    | Progress indicators       |
| `SiaModel`      | —            | Model name display        |
| `SiaUsage`      | —            | Token usage display       |
| `SiaStatus`     | —            | Status display            |

**Tool Approval:**

| Group            | Default Link | Description             |
| ---------------- | ------------ | ----------------------- |
| `SiaApproveInfo` | `StatusLine` | Standard risk level     |
| `SiaApproveSafe` | `StatusLine` | Safe/low risk level     |
| `SiaApproveWarn` | `StatusLine` | Warning/high risk level |

**Insert/Diff Mode:**

| Group                  | Default Link | Description                  |
| ---------------------- | ------------ | ---------------------------- |
| `SiaInsert`            | `DiffAdd`    | Inserted text in insert mode |
| `SiaInsertPostProcess` | `DiffChange` | Post-processed text          |
| `SiaReplace`           | `DiffChange` | Replaced text in diff mode   |

**Todos & Tasks:**

| Group               | Default Link      | Description           |
| ------------------- | ----------------- | --------------------- |
| `SiaTodoActive`     | `DiagnosticWarn`  | Active todo items     |
| `SiaTodoPending`    | `Comment`         | Pending todo items    |
| `SiaTodoDone`       | `DiagnosticOk`    | Completed todo items  |
| `SiaTodoSkipped`    | `NonText`         | Skipped todo items    |
| `SiaStatusActive`   | `DiagnosticHint`  | Running agent tasks   |
| `SiaAgentCompleted` | `DiagnosticOk`    | Completed agent tasks |
| `SiaAgentFailed`    | `DiagnosticError` | Failed agent tasks    |
