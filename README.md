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

- `:Sia [query]` sends the query and opens a split view with the response.
- `:Sia [query]` if run from a conversation, continues the conversation with the new query.
- `:Sia /prompt [query]` executes the prompt with the optional additional query.
- `:Sia! [query]` sends the query and inserts the response.

- `:SiaFile` displays the files in the global file list; or if run from a split, shows the files associated with the current conversation.
- `:SiaFile patterns` adds files matching the patterns to the global file list; or if run from a split, adds them to the current conversation.
- `:SiaFileDelete patterns` removes files matching the patterns from the global file list; or if run from a split, removes them from the current conversation.

- `:SiaAccept` accepts a suggested edit.
- `:SiaReject` rejects a suggested edit.

**Ranges**

Any range is supported, for example:

- `:'<,'>Sia! [query]` send the selected lines and query and diff the response
- `:'<,'>Sia [query]` send the selected lines and query and open a split with the response.
- `:'<,'>Sia /prompt [query]` execute the prompt with the extra query.

**Examples**

- `:%Sia fix the test function` - open a split with a fix to the test function.
- `:Sia write snake in pygame` - open a split with the answer.
- `:Sia /doc numpydoc` - document the function or class under cursor with numpydoc format.
- `:SiaFile a.py b.py | Sia move the function foo_a to b.py`
- `:%Sia /diagnostic` - open a split with a solution to diagnostics in the current file.

### Suggested keybindings:

We can bind visual and operator mode bindings to

- `<Plug>(sia-append)` append the current selection or operator mode selection
  to the current visible split.
- `<Plug>(sia-execute)` execute the default prompt (`vim.b.sia`) with
  selection or operator mode selection.

```lua
keys = {
  { "gza", mode = { "n", "x" }, "<Plug>(sia-append)" },
  { "gzz", mode = { "n", "x" }, "<Plug>(sia-execute)" },
}
```

Then we can send the current paragraph to the default prompt with `gzzip` or
append the current method (assuming `treesitter-textobjects`) to the ongoing
chat with `gzaam`.

Sia also creates Plug bindings for all actions using
`<Plug>(sia-execute-<ACTION>)`, e.g., `<Plug>(sia-execute-explain)` for the
default action `/explain`.

```lua
keys = {
  { "gze", mode = { "n", "x" }, "<Plug>(sia-execute-explain)" },
}
```

**Chat**

In the split view (with `ft=sia`), we can bind the following mappings:

```lua
keys = {
  { "cp", mode = "n", "<Plug>(sia-peek-context)", ft = "sia" },
  { "cx", mode = "n", "<Plug>(sia-delete-instruction)", ft = "sia" },
  { "gr", mode = "n", "<Plug>(sia-replace-block)", ft = "sia" },
  { "gR", mode = "n", "<Plug>(sia-replace-all-blocks)", ft = "sia" },
  { "ga", mode = "n", "<Plug>(sia-insert-block-above)", ft = "sia" },
  { "gb", mode = "n", "<Plug>(sia-insert-block-below)", ft = "sia" },
  { "<CR>", mode = "n", "<Plug>(sia-reply)", ft = "sia" },
}
```

- `<Plug>(sia-peek-context)`: view each context added to the chat
- `<Plug>(sia-delete-instruction)`: delete instructions from the chat
- `<Plug>(sia-replace-block)`: when the cursor is on a code block, apply the suggested edit.
- `<Plug>(sia-replace-all-blocks)`: for all code blocks in the chat, apply the suggested edits and open a quickfix list.
- `<Plug>(sia-insert-block-above)`: insert the code block above the cursor.
- `<Plug>(sia-insert-block-below)`: insert the code block below the cursor.
- `<Plug>(sia-reply)`: open a split view where we can compose a longer query.

When inserting suggestions, Sia will create markers in the code that needs to be accepted or rejected.

```lua
keys = {
  { "ct", mode = "n", "<Plug>(sia-accept)", desc = "Accept change" },
  { "co", mode = "n", "<Plug>(sia-reject)", desc = "Accept change" },
}
```

Sia will insert markers like these, when replacing all blocks:

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

To accept the suggestion, we can call `SiaAccept` or the mapping bound to
`<Plug>(sia-accept)` and to reject we call `SiaReject` or the mapping bound to
`<Plug>(sia-reject)`. For example, to accept all suggestions we could call
`:cdo SiaAccept` when all changes are in the quickfix list.
