# Keybindings

Sia does not set any global keybindings by default. The examples below use
[lazy.nvim](https://github.com/folke/lazy.nvim) `keys` syntax.

## Suggested Global Keybindings

```lua
keys = {
  -- Append selection or operator-pending text to the visible chat
  { "Za", mode = { "n", "x" }, "<Plug>(sia-add-context)" },

  -- Execute the buffer's default prompt (vim.b.sia) with the selection
  { "ZZ", mode = { "n", "x" }, "<Plug>(sia-execute)" },

  -- Toggle the last chat window
  { "<Leader>at", function() require("sia").chat.toggle() end, desc = "Toggle Sia chat" },

  -- Open compose window for a new conversation
  { "<Leader>ap", function() require("sia").chat.compose() end, desc = "Compose new chat" },

  -- Accept or reject all changes in the buffer
  { "<Leader>aa", function() require("sia").edit.accept_all() end, desc = "Accept all changes" },
  { "<Leader>ar", function() require("sia").edit.reject_all() end, desc = "Reject all changes" },

  -- Show changes in diff view and quickfix
  { "<Leader>ad", function() require("sia").edit.show() end, desc = "Show diff" },
  { "<Leader>aq", function() require("sia").edit.open_qf() end, desc = "Show changes in quickfix" },

  -- Navigate between changes (falls back to native [c/]c in diff mode)
  {
    "[c", function()
      if vim.wo.diff then vim.api.nvim_feedkeys("[c", "n", true) return end
      require("sia").edit.prev()
    end,
    desc = "Previous change",
  },
  {
    "]c", function()
      if vim.wo.diff then vim.api.nvim_feedkeys("]c", "n", true) return end
      require("sia").edit.next()
    end,
    desc = "Next change",
  },

  -- Accept or reject the change under the cursor
  { "ga", function() require("sia").edit.accept() end, desc = "Accept change" },
  { "gx", function() require("sia").edit.reject() end, desc = "Reject change" },
}
```

With `<Plug>(sia-add-context)` and `<Plug>(sia-execute)` you can use operator
mode. For example, `ZZip` sends the current paragraph to the default prompt,
and `Zaaam` appends a treesitter method to the chat.

## Action Plug Mappings

Sia creates `<Plug>` bindings for all registered actions using the pattern
`<Plug>(sia-execute-<ACTION>)`. You can map them directly:

```lua
keys = {
  { "Zd", mode = { "n", "x" }, "<Plug>(sia-execute-doc)" },
}
```

## Chat Buffer Keybindings

Inside a chat window (`ft=sia`), you can bind these navigation mappings:

```lua
keys = {
  -- Open a reply buffer to continue the conversation
  { "<CR>", require("sia").chat.reply, ft = "sia" },

  -- Browse conversation messages
  { "p", require("sia").ui.messages, ft = "sia" },

  -- Toggle todo panel
  { "t", require("sia").ui.todos, ft = "sia" },

  -- Toggle agent/process status panel
  { "a", require("sia").ui.status, ft = "sia" },

  -- Show referenced files in quickfix
  { "c", require("sia").ui.contexts, ft = "sia" },
}
```

## Tool Approval Keybindings

If you use [async confirmation](../4-permissions/1-confirmation.md), these
bindings let you handle pending tool approvals:

```lua
keys = {
  { "<Leader>ac", function() require("sia").confirm.prompt() end, desc = "Confirm pending tool" },
  { "<Leader>ay", function() require("sia").confirm.accept() end, desc = "Accept pending tool" },
  { "<Leader>aA", function() require("sia").confirm.always() end, desc = "Always allow pending tool" },
  { "<Leader>an", function() require("sia").confirm.decline() end, desc = "Decline pending tool" },
  { "<Leader>ae", function() require("sia").confirm.expand() end, desc = "Expand pending tools" },
}
```

