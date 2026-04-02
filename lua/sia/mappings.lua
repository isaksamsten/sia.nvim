local utils = require("sia.utils")
local NO_ACTION_ERROR = "sia: no available action selected"

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
      local get_context =
        require("sia.instructions").current_context({ show_line_numbers = true })
      local content, region = get_context({
        buf = vim.api.nvim_get_current_buf(),
        mode = "v",
      })
      if content then
        strategy.conversation:add_user_message(content, region, true)
      end
    end,
    only_visible = true,
  })
end

function _G.__sia_add_context(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > 0 then
    require("sia.utils").with_chat_strategy({
      on_select = function(strategy)
        local get_context =
          require("sia.instructions").current_context({ show_line_numbers = true })
        local content, region = get_context({
          buf = vim.api.nvim_get_current_buf(),
          pos = { start_line, end_line },
          mode = "v",
        })
        if content then
          strategy.conversation:add_user_message(content, region, true)
        end
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
  local pos = { start_line, end_line }
  --- @type sia.Invocation
  local invocation = {
    pos = pos,
    mode = "v",
    bang = false,
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
  }
  local config = require("sia.config")
  local action
  if _G.__sia_execute_action == nil and vim.b.sia then
    action = config.options.actions[vim.b.sia]
  elseif _G.__sia_execute_action then
    action = config.options.actions[_G.__sia_execute_action]
  end
  _G.__sia_execute_action = nil

  if action and not utils.is_action_disabled(action) then
    local conversation = require("sia.conversation").from_action(action, invocation)
    local strategy =
      require("sia.strategy").from_action(action, invocation, conversation)
    require("sia.assistant").execute_strategy(strategy)
  else
    vim.api.nvim_echo({ { NO_ACTION_ERROR, "ErrorMsg" } }, true, {})
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
      ":<C-U>lua require('sia.mappings').execute_visual_with_action('/"
        .. action
        .. "', vim.fn.visualmode())<CR>",
      { noremap = true, silent = true }
    )
  end
end

return M
