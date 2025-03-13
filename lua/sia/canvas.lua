local M = {}

local CHAT_NS = vim.api.nvim_create_namespace("sia_chat")
local PROGRESS_NS = vim.api.nvim_create_namespace("sia_chat")
local MODEL_NS = vim.api.nvim_create_namespace("sia_chat_model")

--- @class sia.Canvas
local Canvas = {}

--- @param messages sia.Message[]
function Canvas:render_messages(messages, model) end

--- @param model string?
function Canvas:render_assistant_header(model) end

function Canvas:scroll_to_bottom() end

--- @param content string[][]
function Canvas:update_progress(content) end

function Canvas:render_model(model) end

function Canvas:clear_extmarks() end

function Canvas:clear() end

function Canvas:line_count() end

--- @class sia.ChatCanvas : sia.Canvas
--- @field buf integer
--- @field progress_extmark integer?
--- @field models table<integer, string?>
local ChatCanvas = {}
ChatCanvas.__index = ChatCanvas

--- @param buf integer
function ChatCanvas:new(buf)
  local obj = {
    buf = buf,
    progress_extmark = nil,
    models = {},
  }
  setmetatable(obj, self)
  return obj
end

function ChatCanvas:update_progress(content)
  local buf = self.buf
  self:clear_extmarks()
  table.insert(content, 1, { "🤖 ", "Normal" })
  self.progress_extmark = vim.api.nvim_buf_set_extmark(buf, PROGRESS_NS, self:line_count() - 1, 0, {
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
  pcall(vim.api.nvim_buf_del_extmark, self.buf, PROGRESS_NS, self.progress_extmark)
end

function ChatCanvas:get_win()
  return vim.fn.bufwinid(self.buf)
end

function ChatCanvas:scroll_to_bottom()
  local win = self:get_win()
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(self.buf), 0 })
end

function ChatCanvas:_set_assistant_extmark(line, model)
  if model == nil then
    return false
  end
  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line - 1, 0, {
    end_line = line,
    hl_eol = true,
    hl_group = "SiaAssistant",
    hl_mode = "combine",
    virt_text = { { model, "SiaModel" } },
    virt_text_pos = "right_align",
  })
end

function ChatCanvas:_set_user_extmark(line)
  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line - 1, 0, {
    end_line = line,
    hl_mode = "combine",
    hl_eol = true,
    hl_group = "SiaUser",
  })
end
--- @param messages sia.Message[]
--- @param model string?
function ChatCanvas:render_messages(messages, model)
  for _, message in ipairs(messages) do
    if message:is_shown() then
      local content = message:get_content()
      if content then
        local line_count = vim.api.nvim_buf_line_count(self.buf)
        local heading = "/you"
        if message.role == "assistant" then
          heading = "/sia"
        end
        if line_count == 1 then
          vim.api.nvim_buf_set_lines(self.buf, line_count - 1, line_count, false, { heading, "" })
          if heading == "/sia" then
            self:_set_assistant_extmark(line_count, model)
          else
            self:_set_user_extmark(line_count)
          end
        else
          vim.api.nvim_buf_set_lines(self.buf, line_count, line_count, false, { "", heading, "" })
          if heading == "/sia" then
            self:_set_assistant_extmark(line_count + 1, model)
          else
            self:_set_user_extmark(line_count + 1)
          end
        end
        line_count = vim.api.nvim_buf_line_count(self.buf)
        vim.api.nvim_buf_set_lines(self.buf, line_count - 1, line_count, false, content)
      end
    end
  end
  self:scroll_to_bottom()
end

--- @param model string?
function ChatCanvas:render_assistant_header(model)
  local buf = self.buf
  if self:line_count() == 1 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "/sia", "" })
    self:_set_assistant_extmark(1, model)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "/sia", "" })
    self:_set_assistant_extmark(self:line_count() - 1, model)
  end
  self:scroll_to_bottom()
end

function ChatCanvas:clear()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
end

function ChatCanvas:line_count()
  return vim.api.nvim_buf_line_count(self.buf)
end

M.ChatCanvas = ChatCanvas

return M
