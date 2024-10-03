local SplitStrategy = require("sia.strategy").SplitStrategy
local Message = require("sia.conversation").Message
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
  local last = SplitStrategy.last()
  if last then
    last.conversation:add_message(Message:from_table(require("sia.messages").current_buffer(true), {
      buf = vim.api.nvim_get_current_buf(),
      cursor = vim.api.nvim_win_get_cursor(0),
    }))
    vim.notify(string.format("Adding context to %s", last:get_name()))
  else
    vim.notify("Can't determine *sia* buffer")
  end
end

function _G.__sia_add_context(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > 0 then
    local last = SplitStrategy.last()
    if last then
      last.conversation:add_message(Message:from_table(require("sia.messages").current_buffer(true), {
        buf = vim.api.nvim_get_current_buf(),
        cursor = vim.api.nvim_win_get_cursor(0),
        start_line = start_line,
        end_line = end_line,
        mode = "v",
      }))
      vim.notify(string.format("Adding context to %s", last:get_name()))
    else
      vim.notify("Can't determine *sia* buffer")
    end
  end
end

function _G.__sia_execute(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line == 0 or end_line == 0 then
    vim.notify("Empty selection")
    _G.__sia_execute_action = nil -- reset
    return
  end

  --- @type sia.ActionArgument
  local args = {
    start_line = start_line,
    end_line = end_line,
    mode = "v",
    buf = vim.api.nvim_get_current_buf(),
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
      local win = utils.get_window_for_buffer(last.buf)
      if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, true)
      else
        vim.cmd(last.options.cmd)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, last.buf)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-replace-block)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local block = split:find_block(line)
      if block then
        require("sia.blocks").replace_block(block, config.options.defaults.replace)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-insert-block-above)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local block = split:find_block(line)
      if block then
        require("sia.blocks").insert_block(block, config.options.defaults.replace, -1)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-insert-block-below)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local block = split:find_block(line)
      if block then
        require("sia.blocks").insert_block(block, config.options.defaults.replace)
      end
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-show-context)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local contexts, _ = split.conversation:get_context_messages()
      local items = {}
      for _, message in ipairs(contexts) do
        table.insert(items, {
          bufnr = message.context.buf,
          filename = utils.get_filename(message.context.buf, ":."),
          lnum = message.context.pos[1],
          text = message:get_information()
            or string.format("Line %d to %d", message.context.pos[1], message.context.pos[2]),
        })
      end
      vim.fn.setqflist(items, "r")
      vim.cmd("copen")
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-delete-context)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local contexts, mappings = split.conversation:get_context_messages()
      vim.ui.select(contexts, {
        prompt = "Delete context",
        --- @param message sia.Message
        format_item = function(message)
          return string.format(
            '"%s" line %d to %d',
            utils.get_filename(message.context.buf, ":."),
            message.context.pos[1],
            message.context.pos[2]
          )
        end,
        --- @param idx integer?
      }, function(_, idx)
        if idx then
          split.conversation:remove_message(mappings[idx])
        end
      end)
    end
  end, { noremap = true, silent = true })

  vim.keymap.set("n", "<Plug>(sia-peek-context)", function()
    local split = SplitStrategy.by_buf()
    if split then
      local contexts, mappings = split.conversation:get_context_messages()
      vim.ui.select(contexts, {
        prompt = "Peek context",
        --- @param message sia.Message
        format_item = function(message)
          return string.format(
            '"%s" %s',
            utils.get_filename(message.context.buf, ":."),
            message:get_information() or string.format("line %d to %d", message.context.pos[1], message.context.pos[2])
          )
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
              title = string.format(
                "%s %s",
                utils.get_filename(item.context.buf),
                item:get_information() or string.format("line %d to %d", item.context.pos[1], item.context.pos[2])
              ),
              title_pos = "center",
            })
            vim.wo[win].wrap = true
            vim.keymap.set("n", "q", function()
              vim.api.nvim_win_close(win, true)
            end, { buffer = buf })

            vim.keymap.set("n", "x", function()
              vim.ui.input({
                prompt = "Delete context (y/N)? ",
              }, function(response)
                if response == "y" then
                  split.conversation:remove_message(mappings[idx])
                  vim.api.nvim_win_close(win, true)
                end
              end)
            end, { buffer = buf })
          end
        end
      end)
    end
  end, { noremap = true, silent = true })

  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-append-buffer)",
    ":lua __sia_add_buffer()<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-append)",
    ":set opfunc=v:lua.__sia_add_context<CR>g@",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "x",
    "<Plug>(sia-append)",
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
