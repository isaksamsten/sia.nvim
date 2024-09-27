local M = {}

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

return M
