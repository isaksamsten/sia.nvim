local M = {}

--- Resolves a given prompt based on configuration options and context.
--- This function handles both named prompts and ad-hoc prompts, adjusting the behavior
--- based on the current file type and provided options.
---
--- @param argument [string]
--- @param opts sia.ActionArgument
--- @return sia.config.Action?
function M.resolve_action(argument, opts)
  local config = require("sia.config")
  local action
  if vim.startswith(argument[1], "/") and vim.bo.ft ~= "sia" then
    action = vim.deepcopy(config.options.actions[argument[1]:sub(2)])
    if action == nil then
      vim.notify(argument[1] .. " does not exists")
      return nil
    end

    if action.input and action.input == "require" and #argument < 2 then
      vim.notify(argument[1] .. " requires input")
      return nil
    end

    if #argument > 1 and not (action.input and action.input == "ignore") then
      table.insert(action.instructions, { role = "user", content = table.concat(argument, " ", 2) })
    end
  else
    local action_mode = M.get_action_mode(opts)
    action = vim.deepcopy(config.options.defaults.actions[action_mode])
    table.insert(action.instructions, { role = "user", content = table.concat(argument, " ") })
  end
  return action
end

--- @param action sia.config.Action
function M.is_action_disabled(action)
  if action.enabled == false or (type(action.enabled) == "function" and not action.enabled()) then
    return true
  end
  return false
end

--- @param opts sia.ActionArgument
--- @return sia.config.ActionMode
function M.get_action_mode(opts)
  if vim.bo[opts.buf].ft == "sia" then
    return "split"
  end

  if opts.bang and opts.mode == "n" then
    return "insert"
  elseif opts.bang and opts.mode == "v" then
    return "diff"
  else
    return "split"
  end
end

--- @param buf integer
--- @return integer? win
function M.get_window_for_buffer(buf)
  local windows = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

--- @param buf integer
--- @param query string?
function M.get_filename(buf, query)
  local full_path = vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(full_path, query or ":t")
end

--- @param start_line integer
--- @param end_line integer
--- @param opts { buf: integer?, return_table: boolean?, show_line_numbers: boolean? }?
function M.get_code(start_line, end_line, opts)
  opts = opts or {}
  local lines = {}
  if end_line == -1 then
    end_line = vim.api.nvim_buf_line_count(opts.buf or 0)
  end
  local buf = opts.buf or 0
  for line_num = start_line, end_line do
    local line
    if opts.show_line_numbers then
      line = string.format("%d: %s", line_num, vim.fn.getbufoneline(buf, line_num))
    else
      line = string.format("%s", vim.fn.getbufoneline(buf, line_num))
    end
    table.insert(lines, line)
  end

  if opts.return_table == true then
    return lines
  else
    return table.concat(lines, "\n")
  end
end

--- @param start_line integer
--- @param end_line integer?
--- @param opts { buf: integer?, min_severity: vim.diagnostic.Severity }?
function M.get_diagnostics(start_line, end_line, opts)
  if end_line == nil then
    end_line = start_line
  end

  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local min_severity = opts.min_severity or vim.diagnostic.severity

  local diagnostics = {}

  for line_num = start_line, end_line do
    local line_diagnostics = vim.diagnostic.get(buf, {
      lnum = line_num - 1,
      severity = { min = min_severity },
    })

    if next(line_diagnostics) ~= nil then
      for _, diagnostic in ipairs(line_diagnostics) do
        table.insert(diagnostics, {
          line_number = line_num,
          message = diagnostic.message,
          severity = vim.diagnostic.severity[diagnostic.severity],
        })
      end
    end
  end

  return diagnostics
end

local ignore_ft = {
  "help",
  "man",
  "git",
  "fugitive",
  "netrw",
  "log",
  "packer",
  "dashboard",
  "TelescopePrompt",
  "NvimTree",
  "vista",
  "terminal",
  "diff",
  "qf",
  "lspinfo",
  "harpoon",
  "outline",
  "sia",
  "neotest-summary",
  "neotest-output-panel",
}

--- @param current_buf integer
--- @param callback fun(item: { buf: integer, win: integer, name: string }):nil
function M.select_other_buffer(current_buf, callback)
  local other = {}
  local tab_wins = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(tab_wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if
      buf ~= current_buf
      and vim.api.nvim_buf_is_loaded(buf)
      and not vim.tbl_contains(other, function(v)
        return v.buf == buf
      end, { predicate = true })
    then
      local ft = vim.bo[buf].filetype
      if not vim.list_contains(ignore_ft, ft) then
        local name = vim.api.nvim_buf_get_name(buf)
        table.insert(other, { buf = buf, win = win, name = name })
      end
    end
  end
  if #other == 0 then
    return
  elseif #other == 1 then
    callback(other[1])
  else
    vim.ui.select(other, {
      format_item = function(item)
        return item.name
      end,
    }, function(choice)
      if choice then
        callback(choice)
      end
    end)
  end
end

return M
