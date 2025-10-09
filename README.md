<p align="center">
<img src="https://raw.githubusercontent.com/isaksamsten/sia.nvim/refs/heads/main/assets/logo.png?raw=true" alt="Logo" width="200px">
</p>
<h1 align="center">sia.nvim</h1>

An LLM assistant for Neovim.

Supports: OpenAI, Copilot, OpenRouter and Gemini (and any other OpenAI API compliant LLM).

## ✨ Features

https://github.com/user-attachments/assets/ac11de80-9979-4f30-803f-7ad79991dd13

https://github.com/user-attachments/assets/48cb1bb6-633b-412c-b33c-ae0b6792a485

https://github.com/user-attachments/assets/af327b9d-bbe1-47d6-8489-c8175a090a70

https://github.com/user-attachments/assets/ea037896-89fd-4660-85b6-b058423be2f6

## ⚡️ Requirements

- Neovim >= **0.11**
- curl
- Access to OpenAI API, Copilot or Gemini

## 📦 Installation

1. Install using a Lazy:

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

2. [get an OpenAI API key](https://platform.openai.com/docs/api-reference/introduction) and add it to your environment as `OPENAI_API_KEY`, enable Copilot (use the vim plugin to set it up) or add Gemini API key to your environment as `GEMINI_API_KEY`.

## ⚙️ Configuration

Sia can be customized both globally (in your Neovim config) and per-project
(using `.sia/config.json`).

### Global Configuration

Configure Sia in your `init.lua`:

```lua
require("sia").setup({
  -- Model defaults
  defaults = {
    model = "openai/gpt-4.1",           -- Main model for conversations
    fast_model = "openai/gpt-4.1-mini", -- Fast model for quick tasks
    plan_model = "openai/o3-mini",       -- Model for planning and reasoning
    temperature = 0.3,                   -- Creativity level (0-1)

    -- UI behavior
    ui = {
      use_vim_ui = false,    -- Use Vim's built-in input/select
      show_signs = true,     -- Show signs in the gutter for changes
      char_diff = true,      -- Show character-level diffs
    },

    -- File operations
    file_ops = {
      trash = true,                      -- Move deleted files to trash
      create_dirs_on_rename = true,      -- Create directories when renaming
      restrict_to_project_root = true,   -- Restrict file operations to project
    },

    -- Default context settings
    context = {
      max_tool = 30,         -- Maximum tool calls before pruning occurs
      exclude = {},          -- Tool names to exclude from pruning
      clear_input = false,   -- Whether to clear tool input parameters during pruning
      keep = 20,             -- Number of recent tool calls to keep after pruning
    },
  },

  -- Add custom actions (see Customizing Actions below)
  actions = {
    -- Your custom actions here
  }
})
```

### Autocommands

`sia.nvim` emits the following autocommands:

- `SiaUsageReport`: when the number of tokens are known
- `SiaStart`: query has been submitted
- `SiaComplete`: the query is completed
- `SiaError`: on errors in the LLM

## 🚀 Usage

**Normal Mode**

- `:Sia [query]` - Sends the query and opens a chat view with the response.
- `:Sia [query]` (from a conversation) - Continues the conversation with the new query.
- `:Sia /prompt [query]` - Executes the prompt with the optional additional query.
- `:Sia! [query]` - Sends the query and inserts the response directly into the buffer.

**Ranges**

Any range is supported. For example:

- `:'<,'>Sia! [query]` - Sends the selected lines along with the query and diffs the response.
- `:'<,'>Sia [query]` - Sends the selected lines and query, opening a chat with the response.
- `:'<,'>Sia /prompt [query]` - Executes the prompt with the extra query for the selected range.

**Examples**

- `:%Sia fix the test function` - Opens a chat with a suggested fix for the test function.
- `:Sia write snake in pygame` - Opens a chat with the generated answer for the query.
- `:Sia /doc numpydoc` - Documents the function or class under the cursor using the numpydoc format.

## Tools

Sia comes with a comprehensive set of tools that enable the AI assistant to
interact with your codebase and development environment:

### File Operations

- **read** - Read file contents with optional line ranges and limits (up to
  2000 lines by default, with line number display)
- **write** - Write complete file contents to create new files or overwrite
  existing ones (ideal for large changes >50% of file content)
- **edit** - Make precise targeted edits using search and replace with fuzzy
  matching and context validation
- **rename_file** - Rename or move files within the project with automatic
  buffer updates
- **remove_file** - Safely delete files with optional trash functionality
  (moves to `.sia_trash` by default)

### Code Navigation & Search

- **grep** - Fast content search using ripgrep with regex support and glob
  patterns (max 100 results, sorted by file modification time)
- **glob** - Find files matching patterns using `fd` (supports `*.lua`,
  `**/*.py`, etc.) with hidden file options
- **workspace** - Show currently visible files with line ranges, cursor
  positions, and background buffers
- **show_locations** - Create navigable quickfix lists for multiple locations
  (supports error/warning/info/note types)
- **get_diagnostics** - Retrieve diagnostics with severity levels and
  source information

### Development Environment

- **bash** - Execute shell commands in persistent sessions with security
  restrictions and output truncation (8000 char limit)
- **fetch** - Retrieve and convert web content to markdown using pandoc, with
  AI-powered content analysis

### Advanced Capabilities

- **dispatch_agent** - Launch autonomous agents with access to read-only tools
  (glob, grep, read) for complex search tasks
- **compact_conversation** - Intelligently summarize and compact conversation
  history when topics change

The assistant combines these tools intelligently to handle complex development
workflows, from simple file edits to multi-file refactoring, debugging, and
project analysis.

### Local Configuration (Per Project)

Create `.sia/config.json` in your project root to customize Sia for that
specific project:

```json
{
  "model": "copilot/gpt-5-mini",
  "fast_model": "openai/gpt-4.1-mini",
  "plan_model": "openai/o3-mini",
  "auto_continue": true,
  "context": {
    "max_tool": 50,
    "exclude": ["grep", "glob"],
    "clear_input": false,
    "keep": 10
  },
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
          "path": [{ "pattern": "%.md$", "negate": true }]
        }
      }
    }
  }
}
```

#### Available Local Configuration Options

- **Model Selection**: Override default models (`model`, `fast_model`,
  `plan_model`) for this project
- **`auto_continue`**: Automatically continue execution when tools are
  cancelled (default: false)
- **`context`**: Project-specific context management (tool pruning behavior)
- **`permission`**: Fine-grained tool access control (see Permission System below)

### Key Configuration Concepts

#### Context Management

Control how Sia manages conversation history and tool call pruning:

- **Tool pruning**: Use `context.max_tool` to set when pruning occurs and
  `context.keep` to control how many recent tool calls are retained
- **Pruning exclusions**: Use `context.exclude` to specify tool names that
  should never be pruned (e.g., `["grep", "glob"]`)
- **Input parameter clearing**: Use `context.clear_input` to also remove tool
  input parameters during pruning

#### Auto-Continue Behavior

When a user cancels a tool operation, Sia normally asks "Continue? (Y/n/[a]lways)". Setting `auto_continue: true` bypasses this prompt and automatically continues execution. This is useful for automated workflows where you want the AI to keep working even if individual operations are cancelled.

#### Memory System

Sia maintains persistent memory across conversations using the `.sia/memory/` directory in your project root. This allows the AI assistant to:

- **Track progress on complex tasks**: Remember what it has tried, what worked,
  and what didn't
- **Learn from iterations**: Build on previous attempts and avoid repeating
  mistakes
- **Resume after interruption**: Continue work seamlessly even if the
  conversation or Neovim session ends
- **Document decisions**: Keep a record of architectural choices, bug fixes,
  and implementation details

**How it works:**

1. The assistant checks `.sia/memory/` at the start of each conversation
2. It reads relevant memory files to understand previous progress
3. As work progresses, it updates memory files with new findings and status
4. Memory files use markdown format for human readability

You can safely view, edit, or delete files in `.sia/memory/` - they're meant to be human-readable and editable. The assistant will adapt to any changes you make.

**Permission behavior:** Tool operations on `.sia/memory/` files never require user confirmation - they are automatically accepted. This ensures the assistant can maintain its memory efficiently without interrupting your workflow.

**Note:** Add `.sia/` to your `.gitignore` if you don't want to commit memory files to version control, or commit them if you want to share context with your team.

### Permission System

The permission system uses Lua patterns to control tool access:

**Rule Precedence** (in order):

1. **Deny rules**: Block operations immediately without confirmation
2. **Ask rules**: Require user confirmation before proceeding
3. **Allow rules**: Auto-approve operations that match all configured patterns

**Rule Structure**:

- Each tool permission must have an `arguments` field
- `arguments`: Object mapping parameter names to pattern arrays
- `choice` (allow rules only): Auto-selection index for multi-choice prompts (default: 1)

**Pattern Format**:
Patterns can be either:

- Simple strings: `"git status"`
- Objects with negate option: `{"pattern": "%.md$", "negate": true}`

**Pattern Matching**:

- Multiple patterns in an array are OR'd together
- All configured argument patterns must match for the rule to apply
- `nil` arguments are treated as empty strings (`""`)
- Non-string arguments are converted to strings with `tostring()`

### Examples

**Auto-approve safe git commands:**

```json
{
  "permission": {
    "allow": {
      "bash": {
        "arguments": {
          "command": ["git status", "git diff.*", "git log.*"]
        }
      }
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
          "target_file": ["src/.*%.(js|ts|py)"]
        }
      }
    },
    "deny": {
      "remove_file": {
        "arguments": {
          "path": [".*%.(config|env).*"]
        }
      }
    }
  }
}
```

This system provides fine-grained control over AI assistant capabilities while
maintaining security and preventing accidental destructive operations.

### Suggested Keybindings

You can bind visual and operator mode selections to enhance your workflow with `sia.nvim`:

- **Append Current Selection**:
  - `<Plug>(sia-append)` - Appends the current selection or operator mode selection to the visible chat.
- **Execute Default Prompt**:
  - `<Plug>(sia-execute)` - Executes the default prompt (`vim.b.sia`) with the current selection or operator mode selection.

```lua
keys = {
  { "Za", mode = { "n", "x" }, "<Plug>(sia-append)" },
  { "ZZ", mode = { "n", "x" }, "<Plug>(sia-execute)" },
  { "<Leader>at", mode = "n", function() require("sia").toggle() end, desc = "Toggle last Sia buffer", },
  { "<Leader>aa", mode = "n", function() require("sia").accept_edits() end, desc = "Accept changes", },
  { "<Leader>ar", mode = "n", function() require("sia").reject_edits() end, desc = "Reject changes", },
  { "<Leader>ad", mode = "n", function() require("sia").show_edits_diff() end, desc = "Diff changes", },
  { "<Leader>aq", mode = "n", function() require("sia").show_edits_qf() end, desc = "Show changes", },
  {
    "[c",
    mode = "n",
    function()
      if vim.wo.diff then
        return "[c"
      end
      require("sia").prev_edit()
    end,
    desc = "Previous edit",
  },
  {
    "]c",
    mode = "n",
    function()
      if vim.wo.diff then
        return "]c"
      end
      require("sia").next_edit()
    end,
    desc = "Next edit",
  },
  { "ga", mode = "n", function() require("sia").accept_edit() end, desc = "Next edit", },
  { "gx", mode = "n", function() require("sia").reject_edit() end, desc = "Next edit", },
}
```

You can send the current paragraph to the default prompt using `gzzip` or append the current method (assuming `treesitter-textobjects`) to the ongoing chat with `gzaam`.

Sia also creates Plug bindings for all actions using `<Plug>(sia-execute-<ACTION>)`, for example, `<Plug>(sia-execute-explain)` for the default action `/explain`.

```lua
keys = {
  { "Ze", mode = { "n", "x" }, "<Plug>(sia-execute-explain)" },
}
```

### Chat Mappings

In the chat view (with `ft=sia`), you can bind the following mappings for efficient interaction:

```lua
keys = {
  { "p", mode = "n", require("sia").show_messages, ft = "sia" },
  { "x", mode = "n", require("sia").remove_message, ft = "sia" },
  { "<CR>", mode = "n", require("sia").open_reply, ft = "sia" },
}
```

### Commands

For the most part, Sia will read and add files, diagnostics, and search results
autonomously. The available commands are:

**Context Management:**

- `SiaAdd file <filename>` - Add a file to the currently visible conversation
- `SiaAdd buffer <buffer>` - Add a buffer to the currently visible conversation
- `SiaAdd context` - Add the current visual mode selection to the currently visible conversation

If there are no visible conversations, Sia will add the context to the next new
conversation that is started.

**Change Management:**

- `SiaAccept` - Accept the change under the cursor
- `SiaReject` - Reject the change under the cursor
- `SiaAccept!` - Accept **all** changes in the current buffer
- `SiaReject!` - Reject **all** changes in the current buffer

**Navigation:**
With the example keybindings configured, you can navigate between changes using `]c` (next change) and `[c` (previous change).

## Change management

If Sia uses the edit tools (insert, write, or edit), it will maintain a diff
state for the buffer in which the changes are inserted. The diff state
maintains two states: the **baseline** (your edits) and the **reference** (Sia's changes). Once you accept a
change, it will be incorporated into baseline and if the change is rejected
it will be removed from reference. This means that you and Sia can make
concurrent changes while you can always opt to reject changes made by Sia.

**NOTE**: If you edit text that overlaps with a pending Sia change, the diff
system considers the entire change as **accepted** and incorporates it into
baseline automatically.

### Example Workflow

1. **Sia makes changes**: After asking Sia to refactor a function, you'll see
   highlighted changes in your buffer
2. **Navigate changes**: Use `]c` and `[c` to jump between individual changes
3. **Review each change**: Position your cursor on a change and decide whether
   to keep it
4. **Accept or reject**:
   - `SiaAccept` to accept the change under cursor
   - `SiaReject` to reject the change under cursor
   - `SiaAccept!` to accept all changes at once
   - `SiaReject!` to reject all changes at once
5. **Continue editing**: You can make your own edits while Sia's changes are
   still pending

### Live Example

[SCREENCAST HERE]

In the following screencast, we see a complete workflow example:

1. **Initial file creation**: We ask Sia to write a small script, and Sia uses
   the `write` tool to create `test.py`
2. **External formatting**: When the file is saved, `ruff format` automatically
   formats it, which modifies the file and moves most changes from **reference**
   into **baseline** (accepting them)
3. **Targeted edits**: We ask Sia to change the dataset from iris to another
   dataset, and Sia uses the `edit` tool to make several targeted changes
4. **Change visualization**: Each change is inserted into **reference** and
   highlighted with both line-level and word-level highlights
5. **Manual review**: We start reviewing changes using `[c` and `]c]` to move
   between changes and `ga` (accept) and make our own edits (removing comments)
6. **Concurrent editing behavior**:
   - When removing comments that don't affect Sia's changes, they remain
     highlighted in **reference**
   - When removing a comment that overlaps with a **reference** change, it's
     automatically accepted and moved to **baseline**
7. **Bulk operations**: Finally, we show all remaining changes in a quickfix
   window and use `cdo norm ga` to accept all changes at once

## Built-in Actions

Sia includes these built-in actions:

- **commit**: Insert a commit message (Git repositories only, `gitcommit` filetype)

  - Example: `Sia /commit`

- **doc**: Insert documentation for the function or class under cursor
  - Example: `Sia /doc`

### Customizing Actions

See `lua/sia/actions.lua` for example actions. Here is a short snippet with a
simple action.

```lua
require("sia").setup({
  actions = {
    yoda = {
      mode = "chat", -- Open in a chat
      chat = { cmd = "split" }, -- We want an horizontal split
      instructions = {
        -- Custom system prompt
        {
          role = "system",
          content = "You are a helpful writer, rewriting prose as Yoda.",
        },
        "current_context", -- builtin instruction to get the current selection
      }
      range = true, -- A range is required
    },

    -- customize a built in instruction ()
    fix = require("sia.actions").fix({chat = true})
  }
})
```

We can use it with `Sia /yoda`.
