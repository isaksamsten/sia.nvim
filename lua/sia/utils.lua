local M = {}

local ns_context = vim.api.nvim_create_namespace("sia_context")

M.BufAppend = {}
M.BufAppend.__index = M.BufAppend

function M.BufAppend:new(bufnr, line, col)
  local obj = {
    bufnr = bufnr,
    line = line or 0,
    col = col or 0,
  }
  setmetatable(obj, self)
  return obj
end

function M.BufAppend:append_substring(substring)
  vim.api.nvim_buf_set_text(self.bufnr, self.line, self.col, self.line, self.col, { substring })
  self.col = self.col + #substring
end

function M.BufAppend:append_newline()
  vim.api.nvim_buf_set_lines(self.bufnr, self.line + 1, self.line + 1, false, { "" })
  self.line = self.line + 1
  self.col = 0
end

--- Appends content to the buffer, processing each line separately-- Advances
--- the buffer for each substring found between newlines.
--- Calls `advance` for each substring and `newline` for each newline character.
--- @param content string The string content to append to the buffer.
function M.BufAppend:append_to_buffer(content)
  local index = 1
  while index <= #content do
    local newline = content:find("\n", index) or (#content + 1)
    local substring = content:sub(index, newline - 1)
    if #substring > 0 then
      self:append_substring(substring)
    end

    if newline <= #content then
      self:append_newline()
    end

    index = newline + 1
  end
end

function M.add_hidden_prompts(buf, prompt)
  vim.api.nvim_buf_clear_namespace(buf, ns_context, 0, -1)
  local lines = {}
  for i, step in ipairs(prompt) do
    if step.role == "user" then
      if type(step.hidden) == "function" then
        local content = step.hidden()
        if content ~= nil then
          table.insert(lines, { { "- " .. step.hidden(), "DiagnosticVirtualTextInfo" } })
        end
      end
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns_context, 0, 0, {
    virt_lines = lines,
    virt_lines_above = true,
  })
end

function M.add_message(buf, step, opts)
  local win
  if buf then
    win = M.get_window_for_buffer(buf)
  else
    buf, win = M.get_current_visible_sia_buffer()
  end

  if buf and win then
    local content_fn = step.content
    step.content = function()
      return content_fn(opts)
    end
    local hidden_fn = step.hidden
    step.hidden = function()
      return hidden_fn(opts)
    end
    local ok, buffer_prompt = pcall(vim.api.nvim_buf_get_var, buf, "_sia_prompt")
    if ok then
      table.insert(buffer_prompt.prompt, step)
      vim.api.nvim_buf_set_var(buf, "_sia_prompt", buffer_prompt)
      vim.api.nvim_buf_set_extmark(buf, ns_context, vim.api.nvim_buf_line_count(buf) - 1, 0, {
        virt_text = { { step.hidden(), "DiagnosticVirtualTextInfo" } },
        virt_text_pos = "overlay",
      })
    end
    return true
  else
    return false
  end
end

function M.get_current_visible_sia_buffer()
  local buffers = vim.api.nvim_list_bufs()
  local buf = nil
  local win = nil
  local count = 0
  for _, current_buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_loaded(current_buf) then
      local ft = vim.api.nvim_buf_get_option(current_buf, "filetype")
      if ft == "sia" then
        win = M.get_window_for_buffer(current_buf)
        buf = current_buf
        count = count + 1
      end
    end
  end
  if count == 1 then
    return buf, win
  else
    return nil, nil
  end
end

function M.get_window_for_buffer(buf)
  local windows = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

function M.filter_hidden(content)
  local filter = {}
  local is_hidden = false
  for _, line in ipairs(content) do
    if string.match(line, "%s*```hidden%s*") then
      is_hidden = true
    elseif is_hidden and string.match(line, "%s*```%s*") then
      is_hidden = false
    end
    if not is_hidden then
      table.insert(filter, line)
    end
  end
  return filter
end

function M.get_filename(buf, query)
  local full_path = vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(full_path, query or ":t")
end

function M.get_code(start_line, end_line, opts)
  local lines = {}
  if end_line == -1 then
    end_line = vim.api.nvim_buf_line_count(opts and opts.bufnr or 0)
  end
  for line_num = start_line, end_line do
    local line
    if opts and opts.show_line_numbers then
      line = string.format("%d: %s", line_num, vim.fn.getbufoneline(opts.bufnr or 0, line_num))
    else
      line = string.format("%s", vim.fn.getbufoneline(opts.bufnr or 0, line_num))
    end
    table.insert(lines, line)
  end

  if opts and opts.return_table == true then
    return lines
  else
    return table.concat(lines, "\n")
  end
end

function M.get_diagnostics(start_line, end_line, bufnr, opts)
  if end_line == nil then
    end_line = start_line
  end

  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local diagnostics = {}

  for line_num = start_line, end_line do
    local line_diagnostics = vim.diagnostic.get(bufnr, {
      lnum = line_num - 1,
      severity = { min = opts.min_severity or vim.diagnostic.severity.HINT },
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
return M
