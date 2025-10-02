local utils = require("sia.utils")
local M = {}

local function get_position(type)
  local start_pos, end_pos
  if type == nil or type == "line" then
    start_pos = vim.fn.getpos("'[")
    end_pos = vim.fn.getpos("']")
  else
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
  end
  return start_pos, end_pos
end

function _G.__sia_add_buffer()
  require("sia.utils").with_chat_strategy({
    on_select = function(strategy)
      local buf = vim.api.nvim_get_current_buf()
      local name = vim.api.nvim_buf_get_name(buf)
      strategy.conversation:add_instruction("current_context", {
        buf = vim.api.nvim_get_current_buf(),
        cursor = vim.api.nvim_win_get_cursor(0),
        tick = require("sia.tracker").ensure_tracked(buf),
        outdated_message = string.format(
          "Previously viewed content from %s - file was modified, read file if needed",
          vim.fn.fnamemodify(name, ":.")
        ),
      })
    end,
    only_visible = true,
  })
end

function _G.__sia_add_context(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > 0 then
    local buf = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    require("sia.utils").with_chat_strategy({
      on_select = function(strategy)
        return strategy.conversation:add_instruction("current_context", {
          buf = vim.api.nvim_get_current_buf(),
          cursor = vim.api.nvim_win_get_cursor(0),
          pos = { start_line, end_line },
          mode = "v",
          tick = require("sia.tracker").ensure_tracked(buf),
          outdated_message = string.format(
            "Previously viewed content from %s - file was modified, read file if needed",
            vim.fn.fnamemodify(name, ":.")
          ),
        })
      end,
      only_visible = true,
    })
  end
end

function _G.__sia_execute(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line == 0 or end_line == 0 then
    _G.__sia_execute_action = nil -- reset
    return
  end

  --- @type sia.ActionContext
  local context = {
    start_line = start_line,
    end_line = end_line,
    pos = { start_line, end_line },
    mode = "v",
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    tick = require("sia.tracker").ensure_tracked(vim.api.nvim_get_current_buf()),
  }
  local action
  if _G.__sia_execute_action == nil and vim.b.sia then
    action = utils.resolve_action({ vim.b.sia }, context)
  elseif _G.__sia_execute_action then
    action = utils.resolve_action({ _G.__sia_execute_action }, context)
  end
  _G.__sia_execute_action = nil

  if action and not utils.is_action_disabled(action) then
    require("sia").main(action, { context = context })
  else
    vim.api.nvim_echo(
      { { "Sia: No available action selected. Please ensure the action is enabled.", "ErrorMsg" } },
      true,
      {}
    )
  end
end

function M.execute_op_with_action(prompt)
  _G.__sia_execute_action = prompt
  vim.cmd("set opfunc=v:lua.__sia_execute")
  return "g@"
end

function M.execute_visual_with_action(prompt, type)
  _G.__sia_execute_action = prompt
  _G.__sia_execute(type)
end

function M.setup()
  local config = require("sia.config")

  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-add-context)",
    ":set opfunc=v:lua.__sia_add_context<CR>g@",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "x",
    "<Plug>(sia-add-context)",
    ":<C-U>lua __sia_add_context(vim.fn.visualmode())<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-execute)",
    ":set opfunc=v:lua.__sia_execute<CR>g@",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "x",
    "<Plug>(sia-execute)",
    ":<C-U>lua __sia_execute(vim.fn.visualmode())<CR>",
    { noremap = true, silent = true }
  )

  for action, _ in pairs(config.options.actions) do
    vim.api.nvim_set_keymap(
      "n",
      "<Plug>(sia-execute-" .. action .. ")",
      'v:lua.require("sia.mappings").execute_op_with_action("/' .. action .. '")',
      { noremap = true, silent = true, expr = true }
    )
    vim.api.nvim_set_keymap(
      "x",
      "<Plug>(sia-execute-" .. action .. ")",
      ":<C-U>lua require('sia.mappings').execute_visual_with_action('/" .. action .. "', vim.fn.visualmode())<CR>",
      { noremap = true, silent = true }
    )
  end
end

return M
