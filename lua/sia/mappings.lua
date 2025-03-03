local SplitStrategy = require("sia.strategy").SplitStrategy
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

--- @param callback fun(strategy: sia.SplitStrategy):boolean
M.add_instruction = function(callback)
  --- @type {buf: integer, win: integer? }[]
  local buffers = SplitStrategy.visible()

  if #buffers == 0 then
    buffers = SplitStrategy.all()
  end

  utils.select_buffer({
    on_select = function(buffer)
      local strategy = SplitStrategy.by_buf(buffer.buf)
      if strategy then
        if callback(strategy) then
          vim.notify(string.format("Adding context to %s", strategy.name))
        else
          vim.notify(string.format("Context already exists %s", strategy.name))
        end
      end
    end,
    format_name = function(buf)
      local strategy = SplitStrategy.by_buf(buf.buf)
      if strategy then
        return strategy.name
      end
    end,
    on_nothing = function()
      vim.notify("No *sia* buffers")
    end,
    source = buffers,
  })
end

function _G.__sia_add_buffer()
  M.add_instruction(function(strategy)
    return strategy.conversation:add_instruction(
      require("sia.instructions").current_buffer({ show_line_numbers = true, fences = true }),
      {
        buf = vim.api.nvim_get_current_buf(),
        pos = vim.api.nvim_win_get_cursor(0),
        cursor = vim.api.nvim_win_get_cursor(0),
      }
    )
  end)
end

function _G.__sia_add_context(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > 0 then
    M.add_instruction(function(strategy)
      return strategy.conversation:add_instruction(
        require("sia.instructions").current_context({ show_line_numbers = true, fences = true }),
        {
          buf = vim.api.nvim_get_current_buf(),
          cursor = vim.api.nvim_win_get_cursor(0),
          pos = { start_line, end_line },
          mode = "v",
        }
      )
    end)
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
  local args = {
    start_line = start_line,
    end_line = end_line,
    pos = { start_line, end_line },
    mode = "v",
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
  }
  local action
  if _G.__sia_execute_action == nil and vim.b.sia then
    action = utils.resolve_action({ vim.b.sia }, args)
  elseif _G.__sia_execute_action then
    action = utils.resolve_action({ _G.__sia_execute_action }, args)
  end
  _G.__sia_execute_action = nil

  if action and not utils.is_action_disabled(action) then
    require("sia").main(action, args)
  else
    vim.notify("Sia: Unavailable action")
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
