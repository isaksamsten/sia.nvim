local M = {}

local CHAT_NS = vim.api.nvim_create_namespace("sia_chat")
local MODEL_NS = vim.api.nvim_create_namespace("sia_chat_model")

--- @class sia.Canvas
local Canvas = {}

--- @param messages sia.Message[]
function Canvas:render_messages(messages) end

--- @param content string[]
function Canvas:render_last(content) end

function Canvas:scroll_to_bottom() end

--- @param content string[][]
function Canvas:update_progress(content) end

function Canvas:render_model(model) end

function Canvas:clear_extmarks() end

function Canvas:clear() end

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

function ChatCanvas:update_progress(content)
  local buf = self.buf
  self:clear_extmarks()
  table.insert(content, 1, { "🤖 ", "Normal" })
  vim.api.nvim_buf_set_extmark(buf, CHAT_NS, self:line_count() - 1, 0, {
    virt_lines = { content },
    virt_lines_above = true,
  })
end

function ChatCanvas:render_model(model)
  vim.api.nvim_buf_clear_namespace(self.buf, MODEL_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(self.buf, MODEL_NS, 0, 0, {
    virt_text = { { "model: ", "NonText" }, { model, "NonText" } },
    virt_text_pos = "right_align",
  })
end

function ChatCanvas:clear_extmarks()
  local buf = self.buf
  vim.api.nvim_buf_clear_namespace(buf, CHAT_NS, 0, -1)
end

function ChatCanvas:get_win()
  return vim.fn.bufwinid(self.buf)
end

function ChatCanvas:scroll_to_bottom()
  local win = self:get_win()
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(self.buf), 0 })
end

--- @param messages sia.Message[]
function ChatCanvas:render_messages(messages)
  local buf = self.buf
  for _, message in ipairs(messages) do
    if message:is_shown() then
      local content = message:get_content()
      if content then
        local line_count = vim.api.nvim_buf_line_count(buf)
        local heading = "# User"
        if message.role == "assistant" then
          heading = "# Sia"
        end
        if line_count == 1 then
          vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { heading, "" })
        else
          vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", "---", "", heading, "" })
        end
        line_count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, content)
      end
    end
  end
  self:scroll_to_bottom()
end

--- @param content string[]
function ChatCanvas:render_last(content)
  local buf = self.buf
  if self:line_count() == 1 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, content)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, content)
  end
  self:scroll_to_bottom()
end

function ChatCanvas:clear()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
end

function ChatCanvas:line_count()
  self:clear_extmarks()
  return vim.api.nvim_buf_line_count(self.buf)
end

M.ChatCanvas = ChatCanvas

return M
