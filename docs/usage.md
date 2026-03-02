# Usage

## Basic Commands

**Buffer-Local Default Prompt:**

You can set `vim.b.sia` to define a default prompt for a buffer. When set,
`:Sia` (without arguments) will use this prompt automatically. For example:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function() vim.b.sia = "/doc numpydoc" end,
})
```

**Normal Mode**

- `:Sia [query]` - Sends the query and opens a chat view with the response.
- `:Sia [query]` (from a conversation) - Continues the conversation with the new query.
- `:Sia /prompt [query]` - Executes the prompt with the optional additional query.
- `:Sia! [query]` - Sends the query and inserts the response directly into the buffer.
- `:Sia -m model [query]` - Overrides the model for this conversation (e.g., `:Sia -m copilot/claude-sonnet-4.5 explain this`).

**Ranges**

Any range is supported. For example:

- `:'<,'>Sia! [query]` - Sends the selected lines along with the query and diffs the response.
- `:'<,'>Sia [query]` - Sends the selected lines and query, opening a chat with the response.
- `:'<,'>Sia /prompt [query]` - Executes the prompt with the extra query for the selected range.

**Examples**

- `:%Sia fix the test function` - Opens a chat with a suggested fix for the test function.
- `:Sia write snake in pygame` - Opens a chat with the generated answer for the query.
- `:Sia /doc numpydoc` - Documents the function or class under the cursor using the numpydoc format.

## Interaction Modes

Sia supports three primary interaction modes that determine how the AI
assistant responds to your queries. Each mode is optimized for different
workflows.

### Chat Mode

**Usage:** `:Sia [query]` or `:Sia /prompt [query]`

Chat mode opens a conversational interface where you can interact with the AI assistant. The assistant can use tools (read files, search code, execute commands) and provide explanations, suggestions, and guidance. This mode is ideal for:

- Exploratory conversations about your codebase
- Getting explanations and suggestions
- Multi-step problem solving where the AI needs to gather information
- Code reviews and architectural discussions

The chat window persists across queries, maintaining conversation history and
allowing you to build on previous exchanges.

After the AI makes suggestions, you can navigate through changes with
`]c`/`[c]` and accept/reject them individually with `ga`/`gx` or in bulk with
`:SiaAccept!`/`:SiaReject!`. See the [Reviewing Changes](changes.md)
documentation for more details.

### Insert Mode

**Usage:** `:Sia! [query]` (without a range)

Insert mode generates text and inserts it directly at the cursor position. The AI's response is inserted as-is without any conversational wrapper. This mode is ideal for:

- Code generation at the current cursor position
- Writing boilerplate code
- Generating documentation or comments
- Quick text generation tasks

The AI is instructed to output only the content to be inserted, without explanations or markdown formatting.

https://github.com/user-attachments/assets/84a412d4-ff42-437a-86cc-bdb8e9eb85e9

### Diff Mode

**Usage:** `:'<,'>Sia! [query]` (with a range or visual selection)

Diff mode shows AI-suggested changes in a side-by-side diff view. The assistant analyzes your selected code and proposes modifications, which you can then accept or reject selectively. This mode is ideal for:

- Refactoring existing code
- Fixing bugs with suggested patches
- Applying style or formatting changes
- Making targeted improvements to selected code

https://github.com/user-attachments/assets/c8a5f031-b032-4a04-96c5-a6407fe43545

### Choosing the Right Mode

- Use **chat mode** when you need to explore, discuss, or get guidance
- Use **insert mode** when you want generated code at your cursor
- Use **diff mode** when you want to modify existing code with AI suggestions

You can customize the default behavior and create custom actions that use any of these modes. See [Actions](actions.md) for details.

## Commands

For the most part, Sia will read and add files, diagnostics, and search results
autonomously. The available commands are:

**Context Management:**

- `SiaAdd file <pattern>` - Add file(s) to the currently visible conversation (supports glob patterns like `src/*.lua`)
- `SiaAdd buffer <buffer>` - Add a buffer to the currently visible conversation
- `:'<,'>SiaAdd context` - Add the current visual selection to the currently visible conversation

If there are no visible conversations, Sia will add the context to the next new
conversation that is started.

**Change Management:**

- `SiaAccept` - Accept the change under the cursor
- `SiaReject` - Reject the change under the cursor
- `SiaAccept!` - Accept **all** changes in the current buffer
- `SiaReject!` - Reject **all** changes in the current buffer
- `SiaDiff` - Show all changes in a diff view

**Tool Approval (Async Mode):**

- `SiaConfirm prompt` - Show the confirm prompt for pending tool operations
- `SiaConfirm accept` - Auto-accept the pending tool operation
- `SiaConfirm decline` - Auto-decline the pending tool operation
- `SiaConfirm preview` - Preview the pending tool operation

Add `!` (e.g., `SiaConfirm! accept`) to process only the first pending confirm.

**Conversation Management:**

- `SiaSave` - Save the current conversation to `.sia/history/` with automatic
  table of contents generation
- `SiaClear` - Remove outdated tool calls and their results from the conversation history
- `SiaBranch <prompt>` - Create a new conversation branching from the current
  one. Copies the full conversation history and continues with the given prompt.
  Optionally override the model with `-m`.
- `SiaDebug` - Show the current conversation's JSON payload in a new buffer

**Shell Process Management:**

- `SiaShell` or `SiaShell list` - List all bash processes (running, completed, failed) for the current conversation
- `SiaShell stop <id>` - Send SIGTERM to a running background process by ID

**Authentication:**

- `SiaAuth codex` - Authenticate with OpenAI Codex (browser-based OAuth)
- `SiaAuth copilot` - Authenticate with GitHub Copilot (device flow)

## Compose Window

Sia provides a floating compose window for starting new conversations with optional model
selection. Call `require("sia").chat.compose()` to open it.

**Keybindings in the compose window:**

- `<CR>` - Submit the prompt
- `m` - Select a different model
- `q` or `<Esc>` - Close the window

## Keybindings

### Suggested Keybindings

You can bind visual and operator mode selections to enhance your workflow with `sia.nvim`:

- **Append Current Context**:
  - `<Plug>(sia-add-context)` - Appends the current selection or operator mode selection to the visible chat.
- **Execute Default Prompt**:
  - `<Plug>(sia-execute)` - Executes the default prompt (`vim.b.sia`) with the current selection or operator mode selection.

```lua
keys = {
  { "Za", mode = { "n", "x" }, "<Plug>(sia-add-context)" },
  { "ZZ", mode = { "n", "x" }, "<Plug>(sia-execute)" },
  { "<Leader>at", mode = "n", function() require("sia").chat.toggle() end, desc = "Toggle last Sia buffer", },
  { "<Leader>ap", mode = "n", function() require("sia").chat.compose() end, desc = "Compose new chat", },
  { "<Leader>aa", mode = "n", function() require("sia").edit.accept_all() end, desc = "Accept changes", },
  { "<Leader>ar", mode = "n", function() require("sia").edit.reject_all() end, desc = "Reject changes", },
  { "<Leader>ad", mode = "n", function() require("sia").edit.show() end, desc = "Diff changes", },
  { "<Leader>aq", mode = "n", function() require("sia").edit.open_qf() end, desc = "Show changes", },
  {
    "[c",
    mode = "n",
    function()
      if vim.wo.diff then
        vim.api.nvim_feedkeys("[c", "n", true)
        return
      end
      require("sia").edit.prev()
    end,
    desc = "Previous edit",
  },
  {
    "]c",
    mode = "n",
    function()
      if vim.wo.diff then
        vim.api.nvim_feedkeys("]c", "n", true)
        return
      end
      require("sia").edit.next()
    end,
    desc = "Next edit",
  },
  -- Tool approval (async mode)
  -- { "<Leader>ac", mode = "n", function() require("sia").confirm.prompt() end, desc = "Confirm pending tool", },
  -- { "<Leader>ay", mode = "n", function() require("sia").confirm.accept() end, desc = "Accept pending tool", },
  -- { "<Leader>an", mode = "n", function() require("sia").confirm.decline() end, desc = "Decline pending tool", },
  { "ga", mode = "n", function() require("sia").edit.accept() end, desc = "Accept edit", },
  { "gx", mode = "n", function() require("sia").edit.accept() end, desc = "Reject edit", },
  -- Or, to be consistent with vim.wo.diff
  --
  -- {
  --   "dp",
  --   mode = "n",
  --   function()
  --     if vim.wo.diff then
  --       vim.api.nvim_feedkeys("dp", "n", true)
  --       return
  --     end
  --     require("sia").edit.accept()
  --   end,
  --   desc = "Accept edit",
  -- },
  -- {
  --   "do",
  --   mode = "n",
  --   function()
  --     if vim.wo.diff then
  --       vim.api.nvim_feedkeys("do", "n", true)
  --       return
  --     end
  --     require("sia").edit.reject()
  --   end,
  --   desc = "Reject edit",
  -- },
}
```

You can send the current paragraph to the default prompt using `ZZip` or append the current method (assuming `treesitter-textobjects`) to the ongoing chat with `Zaaam`.

Sia also creates Plug bindings for all actions using `<Plug>(sia-execute-<ACTION>)`, for example, `<Plug>(sia-execute-doc)` for the built-in `/doc` action.

```lua
keys = {
  { "Zd", mode = { "n", "x" }, "<Plug>(sia-execute-doc)" },
}
```

### Chat Mappings

In the chat view (with `ft=sia`), you can bind the following mappings for efficient interaction:

```lua
keys = {
  { "p", mode = "n", require("sia").show.messages, ft = "sia" },
  { "<CR>", mode = "n", require("sia").chat.reply, ft = "sia" },
  -- toggle the todo view
  { "t", mode = "n", require("sia").show.todos, ft = "sia" },
  -- toggle the status view (agents/processes)
  { "a", mode = "n", require("sia").show.status, ft = "sia" },
  -- show a quickfix window with active context references
  { "c", mode = "n", require("sia").show.contexts, ft = "sia" },
}
```
