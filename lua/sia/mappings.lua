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

  --- @type sia.ActionArgument
  local args = {
    start_line = start_line,
    end_line = end_line,
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
    vim.notify("Unavailable action")
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
  vim.keymap.set("n", "<Plug>(sia-toggle)", function()
    local last = SplitStrategy.last()
    if last and vim.api.nvim_buf_is_valid(last.buf) then
      local win = vim.fn.bufwinid(last.buf)
      if win ~= -1 and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, true)
      else
        vim.cmd(last.options.cmd)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, last.buf)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-reject)", function()
    local buf = vim.api.nvim_get_current_buf()
    require("sia.markers").reject(buf)
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-accept)", function()
    local buf = vim.api.nvim_get_current_buf()
    require("sia.markers").accept(buf)
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-replace-block)", function()
    local split = SplitStrategy.by_buf()

    if split then
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local block = split:find_block(line)
      if block then
        vim.schedule(function()
          require("sia.blocks").replace_block(split.block_action, block, config.options.defaults.replace or {})
        end)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-next-marker)", function()
    require("sia.markers").next()
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-previous-marker)", function()
    require("sia.markers").previous()
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-replace-all-blocks)", function()
    local split = SplitStrategy.by_buf()
    if split then
      vim.schedule(function()
        require("sia.blocks").replace_all_blocks(split.block_action, split.blocks)
      end)
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-insert-block-above)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local block = split:find_block(line)
      if block then
        vim.schedule(function()
          require("sia.blocks").insert_block(split.block_action, block, config.options.defaults.replace, 1)
        end)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-insert-block-below)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local block = split:find_block(line)
      if block then
        vim.schedule(function()
          require("sia.blocks").insert_block(split.block_action, block, config.options.defaults.replace)
        end)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-show-context)", function()
    vim.schedule(function()
      local split = SplitStrategy.by_buf()
      if split then
        local contexts, _ = split.conversation:get_context_messages()
        local items = {}
        for _, message in ipairs(contexts) do
          if message.context then
            table.insert(items, {
              bufnr = message.context.buf,
              filename = utils.get_filename(message.context.buf, ":."),
              lnum = message.context.pos[1],
              text = string.format("lines %d-%d", message.context.pos[1], message.context.pos[2]),
            })
          end
        end
        if #items > 0 then
          vim.fn.setqflist(items, "r")
          vim.cmd("copen")
        end
      end
    end)
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-delete-context)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local contexts, mappings = split.conversation:get_context_instructions()
      if #contexts == 0 then
        vim.notify("No contexts available")
        return
      end
      vim.ui.select(contexts, {
        prompt = "Delete context",
        --- @param idx integer?
      }, function(_, idx)
        if idx then
          split.conversation:remove_instruction(mappings[idx])
        end
      end)
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-peek-context)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local contexts = split.conversation:get_context_messages()
      if #contexts == 0 then
        vim.notify("No contexts available")
        return
      end
      vim.ui.select(contexts, {
        prompt = "Peek context",
        --- @param message sia.Message
        format_item = function(message)
          return message:get_description()
        end,
        --- @param item sia.Message?
        --- @param idx integer
      }, function(item, idx)
        if item then
          local content = item:get_content()
          if content then
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].ft = "markdown"
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
            local win = vim.api.nvim_open_win(buf, true, {
              relative = "win",
              style = "minimal",
              row = vim.o.lines - 3,
              col = 0,
              width = vim.api.nvim_win_get_width(0) - 1,
              height = math.floor(vim.o.lines * 0.2),
              border = "single",
              title = item:get_description(),
              title_pos = "center",
            })
            vim.wo[win].wrap = true
            vim.keymap.set("n", "q", function()
              vim.api.nvim_win_close(win, true)
            end, { buffer = buf })
          end
        end
      end)
    end
  end, { noremap = true, silent = true })

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
