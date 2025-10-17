local M = {}

local CHAT_NS = vim.api.nvim_create_namespace("sia_chat")
local PROGRESS_NS = vim.api.nvim_create_namespace("sia_chat")
local REASONING_NS = vim.api.nvim_create_namespace("sia_chat_reasoning")
local TOOL_RESULT_NS = vim.api.nvim_create_namespace("sia_chat_tool_result")

--- @class sia.CanvasOpts
--- @field temporary_text_hl string?

--- @class sia.Canvas
--- @field buf integer
--- @field progress_extmark integer?
--- @field reasoning_extmark integer?
--- @field reasoning_content string[]
--- @field reasoning_line integer?
--- @field opts sia.CanvasOpts
local Canvas = {}
Canvas.__index = Canvas

--- @param buf integer
--- @param opts sia.CanvasOpts?
function Canvas:new(buf, opts)
  local obj = {
    buf = buf,
    progress_extmark = nil,
    reasoning_extmark = nil,
    reasoning_content = {},
    reasoning_line = nil,
    opts = opts or {},
  }
  setmetatable(obj, self)
  return obj
end

function Canvas:update_tool_progress(content)
  local buf = self.buf
  self:clear_extmarks()
  self.progress_extmark =
    vim.api.nvim_buf_set_extmark(buf, PROGRESS_NS, self:line_count() - 1, 0, {
      virt_lines = content,
      virt_lines_above = false,
    })
end
function Canvas:update_progress(content)
  local buf = self.buf
  self:clear_extmarks()
  table.insert(content, 1, { "🤖 ", "Normal" })
  self.progress_extmark =
    vim.api.nvim_buf_set_extmark(buf, PROGRESS_NS, self:line_count() - 1, 0, {
      virt_lines = { content },
      virt_lines_above = false,
    })
end

--- @param line integer
--- @param end_line integer
function Canvas:highlight_tool(line, end_line)
  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line, 0, {
    end_line = end_line,
    hl_mode = "combine",
    hl_eol = true,
    hl_group = "SiaToolResult",
  })
end

function Canvas:clear_temporary_text()
  vim.api.nvim_buf_clear_namespace(self.buf, REASONING_NS, 0, -1)
  self.reasoning_extmark = nil
  self.reasoning_content = {}
  self.reasoning_line = nil
end

function Canvas:clear_extmarks()
  pcall(vim.api.nvim_buf_del_extmark, self.buf, PROGRESS_NS, self.progress_extmark)
  self.progress_extmark = nil
end

function Canvas:get_win()
  return vim.fn.bufwinid(self.buf)
end

function Canvas:scroll_to_bottom()
  local win = self:get_win()
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(self.buf), 0 })
  end
end

--- @param usage sia.Usage
--- @param extmark_id integer
function Canvas:update_usage(usage, extmark_id)
  if extmark_id == nil then
    return
  end

  local extmark_details = vim.api.nvim_buf_get_extmark_by_id(
    self.buf,
    CHAT_NS,
    extmark_id,
    { details = true }
  )
  if not extmark_details or #extmark_details < 3 then
    return
  end

  local line = extmark_details[1]
  local details = extmark_details[3]
  if not details then
    return nil
  end

  if not details.virt_text then
    return
  end

  local usage_text = {}

  if usage.prompt and usage.prompt > 0 then
    table.insert(usage_text, { "  " .. usage.prompt, "SiaUsage" })
  end

  if usage.completion and usage.completion > 0 then
    table.insert(usage_text, { "  " .. usage.completion, "SiaUsage" })
  end

  if usage.total then
    table.insert(usage_text, { "  " .. usage.total, "SiaUsage" })
  end

  if usage.total_time then
    table.insert(
      usage_text,
      { string.format(" 󰥔 %.1fs", usage.total_time), "SiaUsage" }
    )
  end

  if #usage_text > 0 then
    usage_text[#usage_text][1] = usage_text[#usage_text][1] .. "  "
    for i = #usage_text, 1, -1 do
      table.insert(details.virt_text, 1, usage_text[i])
    end
  end

  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line, 0, {
    id = extmark_id,
    end_line = line + 1,
    hl_eol = true,
    hl_group = "SiaAssistant",
    hl_mode = "combine",
    virt_text = details.virt_text,
    virt_text_pos = "right_align",
  })
end

--- @return integer? extmark_id
function Canvas:_set_assistant_extmark(line, model)
  if model == nil then
    return nil
  end
  return vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line - 1, 0, {
    end_line = line,
    hl_eol = true,
    hl_group = "SiaAssistant",
    hl_mode = "combine",
    virt_text = { { model, "SiaModel" } },
    virt_text_pos = "right_align",
  })
end

function Canvas:_set_user_extmark(line)
  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line - 1, 0, {
    end_line = line,
    hl_mode = "combine",
    hl_eol = true,
    hl_group = "SiaUser",
  })
end
--- @param messages sia.Message[]
--- @param model string?
function Canvas:render_messages(messages, model)
  for _, message in ipairs(messages) do
    if message:is_shown() then
      local content = message:get_content()
      if content and type(content) == "string" then
        local line_count = vim.api.nvim_buf_line_count(self.buf)
        local heading = "/you"
        if message.role == "assistant" then
          heading = "/sia"
        end
        if line_count == 1 then
          vim.api.nvim_buf_set_lines(
            self.buf,
            line_count - 1,
            line_count,
            false,
            { heading, "" }
          )
          if heading == "/sia" then
            self:_set_assistant_extmark(line_count, model)
          else
            self:_set_user_extmark(line_count)
          end
        else
          vim.api.nvim_buf_set_lines(
            self.buf,
            line_count,
            line_count,
            false,
            { "", heading, "" }
          )
          if heading == "/sia" then
            self:_set_assistant_extmark(line_count + 2, model)
          else
            self:_set_user_extmark(line_count + 2)
          end
        end
        line_count = vim.api.nvim_buf_line_count(self.buf)
        vim.api.nvim_buf_set_lines(
          self.buf,
          line_count - 1,
          line_count,
          false,
          vim.split(content, "\n")
        )
      end
    end
  end
  self:scroll_to_bottom()
end

--- @param model string?
--- @return integer? extmark_id
function Canvas:render_assistant_header(model)
  local buf = self.buf
  local id
  if self:line_count() == 1 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "/sia", "" })
    id = self:_set_assistant_extmark(1, model)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "/sia", "" })
    id = self:_set_assistant_extmark(self:line_count() - 1, model)
  end
  self:scroll_to_bottom()
  return id
end

function Canvas:clear()
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(self.buf, TOOL_RESULT_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.buf, REASONING_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.buf, PROGRESS_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.buf, CHAT_NS, 0, -1)
end

function Canvas:line_count()
  return vim.api.nvim_buf_line_count(self.buf)
end

---
function Canvas:append(content)
  local buf = self.buf
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.bo[buf].modifiable = true
    local line_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, content)
    self:update_progress_position()
  end
end

function Canvas:update_progress_position()
  if self.progress_extmark then
    local new_line_count = vim.api.nvim_buf_line_count(self.buf)
    pcall(vim.api.nvim_buf_set_extmark, self.buf, PROGRESS_NS, new_line_count - 1, 0, {
      id = self.progress_extmark,
      virt_lines = vim.api.nvim_buf_get_extmark_by_id(
        self.buf,
        PROGRESS_NS,
        self.progress_extmark,
        { details = true }
      )[3].virt_lines,
      virt_lines_above = false,
    })
  end
end

function Canvas:append_text_at(line, col, text)
  local buf = self.buf
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_text(buf, line, col, line, col, { text })
    self:update_progress_position()
  end
end

function Canvas:append_newline_at(line)
  local buf = self.buf
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, line + 1, line + 1, false, { "" })
    self:update_progress_position()
  end
end

function Canvas:append_temporary_text_at(line, _, text)
  if self.reasoning_line == nil then
    self.reasoning_line = line
  end

  if #self.reasoning_content == 0 then
    self.reasoning_content = { "" }
  end

  local current_line = #self.reasoning_content
  self.reasoning_content[current_line] = self.reasoning_content[current_line] .. text

  self:update_temporary_text()
end

function Canvas:append_temporary_newline_at(line)
  if self.reasoning_line == nil then
    self.reasoning_line = line
  end

  table.insert(self.reasoning_content, "")

  self:update_temporary_text()
end

function Canvas:update_temporary_text()
  local buf = self.buf
  if not vim.api.nvim_buf_is_loaded(buf) or self.reasoning_line == nil then
    return
  end

  if self.reasoning_extmark then
    pcall(vim.api.nvim_buf_del_extmark, buf, REASONING_NS, self.reasoning_extmark)
  end

  local virt_lines = {}
  for _, content_line in ipairs(self.reasoning_content) do
    table.insert(
      virt_lines,
      { { content_line, self.opts.temporary_text_hl or "NonText" } }
    )
  end

  if #virt_lines > 0 then
    self.reasoning_extmark =
      vim.api.nvim_buf_set_extmark(buf, REASONING_NS, self.reasoning_line, 0, {
        virt_lines = virt_lines,
        hl_eol = true,
        virt_lines_above = false,
      })
  end
end

M.Canvas = Canvas

return M
