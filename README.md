<p align="center">
<img src="https://raw.githubusercontent.com/isaksamsten/sia.nvim/refs/heads/main/assets/logo.png?raw=true" alt="Logo" width="200px">
</p>
<h1 align="center">sia.nvim</h1>

An LLM assistant for Neovim.

Supports: OpenAI, Copilot and Gemini (and any other OpenAI API compliant LLM).

Default configuration has the following models: `gpt-4o`, `gpt-4o-mini`,
`o3-mini`, `copilot-gpt-4o`, `copilot-o3-mini`, `copilot-sonnet-3.5`,
`gemini-1.5-flash-8b`, `gemini-1.5-flash`, `gemini-2.0-flash-exp` and
`gemini-1.5-pro`.

## ✨ Features

https://github.com/user-attachments/assets/f43175ac-dfb5-46b1-9bfb-042a689a7c05

https://github.com/user-attachments/assets/aca42a2e-c44f-4312-a75f-81aeff684fb6

https://github.com/user-attachments/assets/7e8ba341-afa7-45c5-8571-225b27a1a2ef

https://github.com/user-attachments/assets/26f0a7e6-2afd-4b69-b4c3-f9945721f442

https://github.com/user-attachments/assets/af327b9d-bbe1-47d6-8489-c8175a090a70

https://github.com/user-attachments/assets/aac7b52d-0e53-4afc-be81-48e3268fca27

## ⚡️ Requirements

- Neovim >= **0.10**
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
- `SiaProgress`: a response has been received
- `SiaComplete`: the query is completed
- `SiaError`: on errors in the LLM
- `SiaEditPost`: after a buffer has been edited

## 🚀 Usage

**Normal Mode**

- `:Sia [query]` - Sends the query and opens a chat view with the response.
- `:Sia [query]` (from a conversation) - Continues the conversation with the new query.
- `:Sia /prompt [query]` - Executes the prompt with the optional additional query.
- `:Sia! [query]` - Sends the query and inserts the response directly into the buffer.

- `:SiaAdd file` - Displays the files in the global file list; if run from a chat, shows the files associated with the current conversation.
- `:SiaAdd file patterns` - Adds files matching the specified patterns to the global file list; if run from a chat, adds them to the current conversation.
- `:SiaRemove patterns` - Removes files matching the specified patterns from the global file list; if run from a chat, removes them from the current conversation.

**Ranges**

Any range is supported. For example:

- `:'<,'>Sia! [query]` - Sends the selected lines along with the query and diffs the response.
- `:'<,'>Sia [query]` - Sends the selected lines and query, opening a chat with the response.
- `:'<,'>Sia /prompt [query]` - Executes the prompt with the extra query for the selected range.

**Examples**

- `:%Sia fix the test function` - Opens a chat with a suggested fix for the test function.
- `:Sia write snake in pygame` - Opens a chat with the generated answer for the query.
- `:Sia /doc numpydoc` - Documents the function or class under the cursor using the numpydoc format.
- `:SiaAdd a.py b.py | Sia move the function foo_a to b.py` - Moves the function `foo_a` from `a.py` to `b.py`.
- `:%Sia /diagnostic` - Opens a chat with a solution to diagnostics in the current file.

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
  { "p", mode = "n", require("sia").preview_context, ft = "sia" },
  { "x", mode = "n", require("sia").remove_context, ft = "sia" },
  { "i", mode = "n", require("sia").replace, ft = "sia" },
  { "I", mode = "n", require("sia").replace_all, ft = "sia" },
  { "r", mode = "n", function() require("sia").replace({apply_marker = true}) end, ft = "sia" },
  { "R", mode = "n", function() require("sia").replace_all({apply_marker = true}) end, ft = "sia" },
  { "a", mode = "n", function() require("sia").insert({above=true}) end, ft = "sia" },
  { "b", mode = "n", require("sia").insert, ft = "sia" },
  { "<CR>", mode = "n", require("sia").open_reply, ft = "sia" },
}
```

- **View Context**: View each context added to the chat.
- **Delete Instruction**: Remove instructions from the chat.
- **Replace Block**: Apply the suggested edit when the cursor is on a code block.
- **Replace All Blocks**: Apply suggested edits to all code blocks in the current response and open a quickfix list.
- **Insert Block Above**: Insert a code block above the cursor.
- **Insert Block Below**: Insert a code block below the cursor.
- **Compose Longer Query**: Open a chat view to compose a longer query.

### Accepting and Rejecting Suggestions

When inserting suggestions, Sia will create markers in the code that need to be accepted or rejected.

Consider using
[conflicting.nvim](https://github.com/isaksamsten/conflicting.nvim) to
highlight and resolve the conflicts.

Add `conflicting.nvim` to dependencies (or separately to also deal with Git merges), and setup an auto command:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "SiaEditPost",
  callback = function(args)
    local buf = args.data.buf
    if buf then
      require("conflicting").track(buf)
    end
  end,
})
```

Markers will look like this when replacing all blocks:

```python
<<<<<<< User
def range_inclusive(start, end):
    return list(range(start, end + 1))

def range_exclusive(start, end):
    return list(range(start, end))

def range_with_step(start, end, step):
    return list(range(start, end, step))

=======
from ranges import range_inclusive, range_exclusive, range_with_step
>>>>>>> Sia
```

If you are using `conflicting.nvim`, you can accept the suggestion from `Sia`
with `Conflicting incoming` (or for all changes in the quickfix list with `:cdo
Conflicting incoming`)

## Customize configuration

### Default actions

In Sia, you can execute various actions using the command `:Sia <action>`. The following actions are bundled in the default configuration:

- **edit**: Edit a selection without confirmation using the instructions.

  - Example: `'<,'>Sia /edit optimize`

- **diagnostic**: Open a chat window with explanations for the diagnostics in the specified range.

  - Example: `'<,'>Sia /diagnostic`

- **commit**: Insert a commit message (enabled only if inside a Git repository and the current file type is `gitcommit`).

  - Example: `Sia /commit`

- **review**: Review the code in the specified range and open a quickfix window with comments.

  - Example: `'<,'>Sia /review`

- **explain**: Open a chat window explaining the current range.

  - Example: `'<,'>Sia /explain focus on the counter`

- **unittest**: Open a chat window with unit tests for the current range or the captured function under the cursor.

- **doc**: Insert documentation for the function or class under the cursor.

  - Example: `Sia /doc`

- **fix**: Inline fix for the issue provided in a quickfix window.
  - Example: `Sia /fix`

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
