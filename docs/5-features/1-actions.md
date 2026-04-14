# Actions

Actions define how Sia handles a specific type of request: what system prompt
to use, which tools are available, and how the output is presented.

## Built-in Actions

Sia includes these built-in actions:

- **/commit** — generates a commit message from the staged diff. Available only
  in `gitcommit` buffers.

  ```vim
  :Sia /commit
  ```

- **/doc** — generates documentation for the function or class under the
  cursor. Automatically captures the surrounding function or class using
  treesitter.
  ```vim
  :Sia /doc
  :Sia /doc numpydoc
  ```

## Custom Actions

Define custom actions in `setup()`:

```lua
local messages = require("sia.config.messages")

require("sia").setup({
  actions = {
    yoda = {
      mode = "chat",
      chat = { cmd = "split" },
      system = {
        "You are a helpful writer, rewriting prose as Yoda.",
      },
      user = {
        messages.user.current_context(),
      },
      range = true,
    },
  },
})
```

Use it with `:Sia /yoda` on a visual selection.

## Action Options

### Core Options

| Option      | Type             | Description                                                             |
| ----------- | ---------------- | ----------------------------------------------------------------------- |
| **mode**    | string           | UI mode: `"chat"`, `"diff"`, `"insert"`, or `"hidden"`                  |
| **system**  | array            | System-level messages (strings or functions returning strings)          |
| **user**    | array            | User-level context messages (functions, strings, or tables)             |
| **model**   | string           | Override the default model                                              |
| **tools**   | function         | `(model) -> tool[]` returning available tools                           |
| **input**   | string           | `"require"` (must include user text) or `"ignore"` (user text not used) |
| **range**   | boolean          | Whether a range/selection is required (default: false)                  |
| **capture** | function         | Auto-capture context (e.g., using treesitter)                           |
| **enabled** | function/boolean | Whether the action is available                                         |

### Mode-Specific Options

**Insert mode** (`mode = "insert"`):

| Option                | Description                                                      |
| --------------------- | ---------------------------------------------------------------- |
| `insert.placement`    | Where to insert: `"cursor"`, `"above"`, `"below"`, or a function |
| `insert.cursor`       | Cursor position after insert: `"start"` or `"end"`               |
| `insert.message`      | Status message: `{ text, highlight_group }`                      |
| `insert.post_process` | Function to transform lines before insertion                     |

**Diff mode** (`mode = "diff"`):

| Option     | Description                                    |
| ---------- | ---------------------------------------------- |
| `diff.cmd` | Command to open diff window (e.g., `"vsplit"`) |
| `diff.wo`  | Window options as array of strings             |

**Chat mode** (`mode = "chat"`):

| Option     | Description                                                                 |
| ---------- | --------------------------------------------------------------------------- |
| `chat.cmd` | Command to open chat window (e.g., `"vsplit"`)                              |
| `chat.wo`  | Window options table                                                        |
| `agents`   | Agent names exposed to this action, without relying on project config       |
| `skills`   | Skill names exposed to this action, without relying on project config       |
| `modes`    | Table of conversation modes (see [Conversation Modes](#conversation-modes)) |

**Hidden mode** (`mode = "hidden"`):

| Option            | Description                                                |
| ----------------- | ---------------------------------------------------------- |
| `hidden.callback` | Function called with `(ctx, content, usage)` on completion |
| `hidden.notify`   | Function called with status messages during execution      |

## Instructions

Actions use two arrays to define what is sent to the model:

- **system** — system-level messages that set behavior and role
- **user** — user-level context messages that provide code, files, and instructions

### System Messages

System messages are strings or functions returning strings.

You can also use these as functions from `require("sia.config.messages").system`:

```lua
local messages = require("sia.config.messages")

system = {
  messages.system.adaptive,
},
```

Or as inline strings:

```lua
system = {
  "You are a code reviewer. Focus on correctness and performance.",
},
```

### User Messages

User messages provide context to the model. They can be strings, functions, or
tables with a `hide` flag. Use them in the `user` array.

Functions receive an `invocation` context and can return content and an optional
region (for tracking file changes):

```lua
local messages = require("sia.config.messages")

user = {
  messages.user.current_context({ show_line_numbers = true }),
  messages.user.current_buffer({ show_line_numbers = true }),
  "Please review this code",
},
```

Built-in user instruction functions from `require("sia.config.messages").user`:

| Function            | Description                                                 |
| ------------------- | ----------------------------------------------------------- |
| `current_context()` | Current selection (visual) or minimal file context (normal) |
| `current_buffer()`  | Entire buffer with line numbers                             |
| `visible_buffers`   | All visible buffers with cursor positions                   |
| `verbatim`          | Raw selection without formatting                            |

Options for `current_context()` and `current_buffer()`:

```lua
local user = require("sia.config.messages").user

user.current_context({ show_line_numbers = true })
user.current_buffer({ show_line_numbers = true, include_cursor = true })
```

To hide a user message from the UI (useful for context that clutters the chat):

```lua
user = {
  { hide = true, content = function(invocation)
    return "Hidden context based on " .. invocation.buf
  end },
},
```

### Action Scoped Agents And Skills

Chat actions can expose a specific set of agents or skills directly:

```lua
require("sia").setup({
  actions = {
    orchestrate = {
      mode = "chat",
      agents = {
        ["code/implement"] = true,
        ["code/explore"] = true,
        ["code/review"] = true,
      },
      skills = {
        ["update-docs"] = true,
      },
      -- ...
    },
  },
})
```

Use this when an action should always see a known set of agents or skills,
without requiring the user to enable them in global settings or
`.sia/config.json`.

## Conversation Modes

Chat actions can include a `modes` table that defines named modes with
tool restrictions and guided prompts. Modes are useful for structured
workflows like planning, reviewing, or exploring before making changes.

### Mode Definition

Each mode is a table with these fields:

| Field            | Type               | Description                                                                  |
| ---------------- | ------------------ | ---------------------------------------------------------------------------- |
| **description**  | string             | Short description of the mode                                                |
| **permissions**  | table              | Tool permission rules (see below)                                            |
| **enter_prompt** | string or function | Prompt injected when the mode activates. Functions receive `state`.          |
| **exit_prompt**  | string or function | Prompt injected when the mode exits. Functions receive `state`.              |
| **init_state**   | function           | Returns a state table passed to prompts. Receives the context.               |
| **deny_message** | function           | Custom deny message. Receives `(tool_name, args, kind)`.                     |
| **truncate**     | boolean            | Remove all mode messages from history on exit, keeping only the exit prompt. |

### Mode Permissions

The `permissions` table controls which tools are available inside the mode:

- **deny** — array of tool names that are completely blocked.
- **allow** — table mapping tool names to `true` (unrestricted) or a rule
  with `arguments` patterns that restrict when the tool can be used.

Tools not mentioned in either list fall through to the normal
[permission system](../4-permissions/2-rules.md).

```lua
permissions = {
  deny = { "bash", "agent" },
  allow = {
    view = true,
    grep = true,
    glob = true,
    write = { arguments = { path = { "(^|/)NOTES_" } } },
  },
}
```

In this example, `bash` and `agent` are blocked. `view`, `grep`, and `glob`
are auto-approved. `write` is allowed only when the **path** argument matches
the pattern `NOTES_`. All other tools use the default permission rules.

### Example: Custom Review Mode

```lua
local messages = require("sia.config.messages")

require("sia").setup({
  actions = {
    chat = {
      mode = "chat",
      modes = {
        review = {
          description = "Review code without making changes",
          permissions = {
            deny = { "edit", "write", "insert", "bash", "agent", "apply_diff" },
            allow = {
              view = true,
              grep = true,
              glob = true,
              diagnostics = true,
              memory = { arguments = { command = { "^view$", "^search$" } } },
            },
          },
          enter_prompt = "Review the code for bugs, security issues, and style problems. "
            .. "Do not make any changes. Write findings to memory when done.",
          exit_prompt = "Review complete. All tools are now available for fixes.",
        },
      },
      system = {
        messages.system.adaptive,
      },
      user = {
        messages.user.system_info,
        messages.user.directory_structure,
        messages.user.visible_buffers,
      },
      -- ... other chat action options
    },
  },
})
```

Activate it with `:Sia @review check the auth module` or type `@review` in
an existing chat.

### Built-in Modes

The default chat action includes the **plan** mode, which restricts the
assistant to read-only tools and plan file writes. See
[Interaction Modes](../2-usage/1-modes.md#conversation-modes) for usage
details.

## Examples

### Insert Mode with Post-Processing

Generate a code summary formatted as a comment block:

```lua
local messages = require("sia.config.messages")

actions = {
  summarize = {
    mode = "insert",
    system = {
      "Generate a brief 1-2 sentence summary of the provided code.",
    },
    user = {
      messages.user.current_context(),
    },
    range = true,
    insert = {
      placement = "above",
      cursor = "end",
      message = { "Generating summary...", "Comment" },
      post_process = function(args)
        local prefix = vim.bo[args.buf].ft == "python" and "# " or "// "
        local result = {}
        for _, line in ipairs(args.lines) do
          if line:match("%S") then
            table.insert(result, prefix .. line)
          end
        end
        return result
      end,
    },
  },
}
```

### Diff Mode for Refactoring

```lua
local messages = require("sia.config.messages")

actions = {
  refactor = {
    mode = "diff",
    diff = {
      cmd = "tabnew % | vsplit",
      wo = { "number", "relativenumber" },
    },
    system = {
      "You are a code reviewer. Analyze the code and suggest improvements "
        .. "for clarity, performance, naming, and reduced complexity. "
        .. "Output the complete refactored code.",
    },
    user = {
      messages.user.current_context(),
      "Refactor this code following best practices.",
    },
    range = true,
    capture = function(ctx)
      return require("sia.capture").treesitter(
        { "function.outer", "class.outer" },
        ctx.buf,
        ctx.cursor
      )
    end,
  },
}
```
