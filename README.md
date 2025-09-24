<p align="center">
<img src="https://raw.githubusercontent.com/isaksamsten/sia.nvim/refs/heads/main/assets/logo.png?raw=true" alt="Logo" width="200px">
</p>
<h1 align="center">sia.nvim</h1>

An LLM assistant for Neovim.

Supports: OpenAI, Copilot, OpenRouter and Gemini (and any other OpenAI API compliant LLM).

## ✨ Features

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

## 📦 Customize

TODO

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

## Local Configuration

Sia supports project-specific configuration through `.sia/config.json` files.
This allows you to customize tool behavior and permissions on a per-project
basis.

### Setting Up Local Configuration

Create a `.sia/config.json` file in your project root:

```json
{
  "model": "copilot/gpt-5-mini",
  "auto_continue": true,
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

Use the local option `model` to override the local default model. The local
configuration can also override both `plan_model` and `fast_model`.

### Configuration Options

Available configuration options in `.sia/config.json`:

- **`model`**: Override the default model for this project
- **`fast_model`**: Override the fast model used for quick operations
- **`plan_model`**: Override the model used for planning operations
- **`auto_continue`**: Automatically continue execution after a tool is cancelled by the user (boolean, default: false)

  When a user cancels a tool operation, Sia normally asks "Continue? (Y/n/[a]lways)". Setting `auto_continue: true`
  bypasses this prompt and automatically continues execution. This is useful for automated workflows where you want
  the AI to keep working even if individual operations are cancelled.

- **`permission`**: Fine-grained tool access control (see Permission System below)

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

- Uses Lua's `string.match()` function directly (not anchored)
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

## Customize configuration

- **commit**: Insert a commit message (enabled only if inside a Git repository and the current file type is `gitcommit`).

  - Example: `Sia /commit`

- **doc**: Insert documentation for the function or class under the cursor.

  - Example: `Sia /doc`

### Customizing actions

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
