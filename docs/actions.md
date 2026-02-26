# Actions

## Built-in Actions

Sia includes these built-in actions:

- **commit**: Insert a commit message (Git repositories only, `gitcommit` filetype)
  - Example: `Sia /commit`

- **doc**: Insert documentation for the function or class under cursor
  - Example: `Sia /doc`

## Customizing Actions

See `lua/sia/actions.lua` for example actions. Here is a short snippet with a
simple action.

### Action Configuration Options

When defining custom actions, you can configure the following options:

**Core Options:**

- `mode` - The UI mode: `"chat"`, `"diff"`, `"insert"`, or `"hidden"`
- `instructions` - Array of instructions (strings or instruction objects) to send to the model
- `system` - Array of system-level instructions (optional)
- `model` - Override the default model for this action (optional)
- `temperature` - Override the default temperature (optional)
- `tools` - Function `(model) -> tool[]` returning tools available to the action (optional)
- `ignore_tool_confirm` - Skip confirmation prompts for tool usage (optional)
- `input` - How to handle user input: `"require"` (prompt must include user text) or `"ignore"` (user text is not used). If omitted, user text is optional.
- `range` - Whether a range/selection is required (default: `false`)
- `capture` - Function to automatically capture context (e.g., using treesitter)
- `enabled` - Function or boolean to determine if action is available

**Mode-Specific Options:**

For `mode = "insert"`:

- `insert.placement` - Where to insert: `"cursor"`, `"above"`, `"below"`, or a function
- `insert.cursor` - Where to place cursor after insert: `"start"` or `"end"`
- `insert.message` - Status message: `[text, highlight_group]`
- `insert.post_process` - Function to transform lines before insertion

For `mode = "diff"`:

- `diff.cmd` - Command to open diff window (e.g., `"vsplit"`, `"split"`)
- `diff.wo` - Window options as array of strings

For `mode = "chat"`:

- `chat.cmd` - Command to open chat window (e.g., `"vsplit"`, `"split"`)
- `chat.wo` - Window options as table

For `mode = "hidden"`:

- `hidden.callback` - Function called with `(ctx, content, usage)` when the response completes
- `hidden.notify` - Function called with status messages during execution

### Built-in Instructions

Sia provides several built-in instructions that you can use by name in your action configurations. These instructions help provide context to the AI model.

**String-named Instructions:**

You can reference these by their string name in the `instructions` array:

- `"current_context"` - Provides the current selection or buffer context
  - In visual mode: sends the selected lines
  - In normal mode: minimal context about the file
  - Options: `require("sia.instructions").current_context({ show_line_numbers = true })`

- `"current_buffer"` - Provides the entire current buffer
  - Sends the full file content with line numbers
  - Options: `require("sia.instructions").current_buffer({ show_line_numbers = true, include_cursor = true })`

- `"visible_buffers"` - Lists all visible buffers in the current tab with cursor positions
  - Useful for giving the AI awareness of your workspace
  - Usage: `require("sia.instructions").visible_buffers()`

- `"verbatim"` - Provides the selection without any formatting
  - Raw text without line numbers or explanations
  - Usage: `require("sia.instructions").verbatim()`

**System-level Instructions:**

These are typically used in the `system` array for specific modes:

- `"model_system"` - Model-dependent system prompt: uses GPT-5 specific instructions for GPT-5 models, falls back to a minimal prompt for others (default for chat action)
- `"default_system"` - A comprehensive default system prompt for coding tasks with collaboration guidelines
- `"minimal_system"` - A minimal system prompt suitable for simpler interactions
- `"prose_system"` - System prompt optimized for writing and prose editing
- `"insert_system"` - System prompt for insert mode (instructs to output only insertable text)
- `"diff_system"` - System prompt for diff mode (instructs to output replacement text)
- `"directory_structure"` - Provides the file tree of the current directory
- `"agents_md"` - Includes AGENTS.md file if it exists in the project
- `"system_info"` - Provides OS, Neovim version, git branch, and timestamp info

**Using Built-in Instructions:**

```lua
-- By string name (for common instructions)
instructions = {
  "current_context",  -- Built-in instruction
  { role = "user", content = "Explain this code" },
}

-- By function call (for instructions with options)
instructions = {
  require("sia.instructions").current_context({ show_line_numbers = false }),
  { role = "user", content = "Explain this code" },
}
```

**Custom Instructions:**

You can also define custom instructions by providing a table with `role` and `content`:

```lua
instructions = {
  {
    role = "user",
    content = function(ctx)
      -- ctx contains: buf, cursor, mode, pos
      return "Custom instruction based on context"
    end,
    hide = true,        -- Don't show in UI
    description = "My custom instruction",
  },
}
```

## Examples

### Example 1: Simple Chat Action

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
        "current_context",
      },
      range = true,
    },
  }
})
```

We can use it with `Sia /yoda`.

### Example 2: Insert Mode with Custom Post-Processing

This action generates a code summary and formats it as a comment block:

```lua
require("sia").setup({
  actions = {
    summarize = {
      mode = "insert",
      system = {
        {
          role = "system",
          content = "Generate a brief 1-2 sentence summary of the provided code.",
        },
      },
      instructions = {
        "current_context",
      },
      range = true,
      insert = {
        placement = "above", -- Insert above the selection
        cursor = "end", -- Place cursor at end of insertion
        message = { "Generating summary...", "Comment" },
        post_process = function(args)
          local lines = args.lines
          local ft = vim.bo[args.buf].ft

          local comment_start, comment_end
          if ft == "lua" then
            comment_start = "-- "
          elseif ft == "python" then
            comment_start = "# "
          elseif ft == "c" or ft == "cpp" or ft == "java" then
            comment_start = "// "
          else
            comment_start = "// "
          end

          local result = {}
          for _, line in ipairs(lines) do
            if line:match("%S") then -- Skip empty lines
              table.insert(result, comment_start .. line)
            end
          end

          return result
        end,
      },
    },
  }
})
```

Use with `Sia /summarize` on a visual selection to get a commented summary.

### Example 3: Diff Mode for Code Refactoring

This action suggests refactoring improvements and shows them in a diff view:

```lua
require("sia").setup({
  actions = {
    refactor = {
      mode = "diff",
      diff = {
        cmd = "tabnew % | vsplit",
        wo = { "number", "relativenumber" },
      },
      system = {
        {
          role = "system",
          content = [[You are an expert code reviewer focused on refactoring.
Analyze the provided code and suggest improvements for:
- Code clarity and readability
- Performance optimizations
- Better naming conventions
- Reduced complexity
- Design pattern improvements

Output the complete refactored code, maintaining all functionality.]],
        },
      },
      instructions = {
        "current_context",
        {
          role = "user",
          content = "Please refactor this code following best practices.",
        },
      },
      range = true,
      capture = require("sia.capture").treesitter({
        "@function.outer",
        "@class.outer"
      }),
    },
  }
})
```

Use `Sia /refactor` on a function or class to see refactoring suggestions in a diff view. You can then accept or reject the changes using Neovim's diff navigation commands.
