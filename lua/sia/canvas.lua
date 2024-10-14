local M = {}

--- @class sia.Canvas
local Canvas = {}

--- @param messages sia.Message[]
function Canvas:render_messages(messages) end

--- @param content string[]
function Canvas:render_last(content) end

function Canvas:line_count() end

--- @class sia.ChatCanvas : sia.Canvas
--- @field buf integer
local ChatCanvas = {}
ChatCanvas.__index = ChatCanvas

--- @param buf integer
function ChatCanvas:new(buf)
  local obj = {
    buf = buf,
  }
  setmetatable(obj, self)
  return obj
end

--- @param messages sia.Message[]
function ChatCanvas:render_messages(messages)
  local buf = self.buf
  for _, message in ipairs(messages) do
    if message.role ~= "system" and not message.persistent and not message.hide == true then
      local content = message:get_content()
      if content then
        local line = vim.api.nvim_buf_line_count(buf)
        local heading = "# User"
        if message.role == "assistant" then
          heading = "# Sia"
        end
        if line == 1 then
          vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { heading, "" })
        else
          vim.api.nvim_buf_set_lines(buf, line, line, false, { "", "---", "", heading, "" })
        end
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, content)
      end
    end
  end
end

--- @param content string[]
function ChatCanvas:render_last(content)
  local buf = self.buf
  if self:line_count() == 1 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, content)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, content)
  end
end

function ChatCanvas:clear()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
end

function ChatCanvas:line_count()
  return vim.api.nvim_buf_line_count(self.buf)
end

M.ChatCanvas = ChatCanvas

return M
