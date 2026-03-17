local M = {}

local CHAT_NS = vim.api.nvim_create_namespace("sia_chat")
local PROGRESS_NS = vim.api.nvim_create_namespace("sia_chat")
local TEMPORARY_NS = vim.api.nvim_create_namespace("sia_chat_temporary")
local TOOL_RESULT_NS = vim.api.nvim_create_namespace("sia_chat_tool_result")

--- @class sia.CanvasOpts
--- @field temporary_text_hl string?

--- @class sia.Canvas
--- @field buf integer
--- @field progress_extmark integer?
--- @field temporary_extmark integer?
--- @field temporary_content string[]
--- @field temporary_line integer?
--- @field opts sia.CanvasOpts
local Canvas = {}
Canvas.__index = Canvas

--- @param buf integer
--- @param opts sia.CanvasOpts?
function Canvas:new(buf, opts)
  local obj = {
    buf = buf,
    progress_extmark = nil,
    temporary_extmark = nil,
    temporary_content = {},
    temporary_line = nil,
    opts = opts or {},
  }
  setmetatable(obj, self)
  return obj
end

function Canvas:update_tool_progress(content)
  local buf = self.buf
  self:clear_progress()
  self.progress_extmark =
    vim.api.nvim_buf_set_extmark(buf, PROGRESS_NS, self:line_count() - 1, 0, {
      virt_lines = content,
      virt_lines_above = false,
    })
end
function Canvas:update_progress(content)
  local buf = self.buf
  self:clear_progress()
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
  vim.api.nvim_buf_clear_namespace(self.buf, TEMPORARY_NS, 0, -1)
  self.temporary_extmark = nil
  self.temporary_content = {}
  self.temporary_line = nil
end

function Canvas:clear_progress()
  pcall(vim.api.nvim_buf_del_extmark, self.buf, PROGRESS_NS, self.progress_extmark)
  self.progress_extmark = nil
end

local function is_reasoning_line(line)
  return line == ">|" or line:match("^>| ") ~= nil
end

local function trim_trailing_empty(lines)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function extract_reasoning_text(message)
  local meta = message.meta or {}
  if type(meta.reasoning_text) == "string" and meta.reasoning_text ~= "" then
    return meta.reasoning_text
  end

  if meta.reasoning and type(meta.reasoning.summary) == "string" then
    return meta.reasoning.summary
  end

  return nil
end

local function format_reasoning_lines(content)
  if type(content) ~= "string" or content == "" then
    return nil
  end

  local lines = trim_trailing_empty(vim.split(content, "\n", { plain = true }))
  if vim.tbl_isempty(lines) then
    return nil
  end

  local formatted = {}
  for _, line in ipairs(lines) do
    if line == "" then
      table.insert(formatted, ">|")
    else
      table.insert(formatted, ">| " .. line)
    end
  end

  return formatted
end

--- @param lnum integer
--- @return string|integer
function M.blockquote_foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  local prev = lnum > 1 and vim.fn.getline(lnum - 1) or ""

  if is_reasoning_line(line) then
    if not is_reasoning_line(prev) then
      return ">1"
    end
    return 1
  end

  return 0
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

--- @param extmark_id integer
--- @param opts {model: string?, usage: sia.Usage?, status_text: string?},
function Canvas:update_assistant_extmark(extmark_id, opts)
  if extmark_id == nil then
    return
  end
  opts = opts or {}

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
  local virt_text = {}

  local usage = opts.usage
  if usage then
    local usage_text = {}

    if usage.total_time then
      table.insert(
        usage_text,
        { string.format(" 󰥔 %.1fs", usage.total_time), "SiaUsage" }
      )
    end

    if #usage_text > 0 then
      usage_text[#usage_text][1] = usage_text[#usage_text][1] .. "  "
      for _, text in ipairs(usage_text) do
        table.insert(virt_text, text)
      end
    end
  end

  if opts.model then
    table.insert(virt_text, { opts.model, "SiaModel" })
  end

  if opts.status_text then
    table.insert(virt_text, { " [" .. opts.status_text .. "]", "SiaStatus" })
  end

  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line, 0, {
    id = extmark_id,
    end_line = line + 1,
    hl_eol = true,
    hl_group = "SiaAssistant",
    hl_mode = "combine",
    virt_text = virt_text,
    virt_text_pos = "right_align",
  })
end

--- @param line integer
--- @param model string?
--- @param status_text string?
--- @return integer? extmark_id
function Canvas:_set_assistant_extmark(line, model, status_text)
  if model == nil then
    return nil
  end
  local virt_text = { { model, "SiaModel" } }
  if status_text then
    table.insert(virt_text, { " [#" .. status_text .. "]", "SiaStatus" })
  end
  return vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line - 1, 0, {
    end_line = line,
    hl_eol = true,
    hl_group = "SiaAssistant",
    hl_mode = "combine",
    virt_text = virt_text,
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
--- @param messages sia.PreparedMessage[]
--- @param model string?
function Canvas:render_messages(messages, model)
  vim.bo[self.buf].modifiable = true
  local last_assistant_turn_id = nil
  for _, message in ipairs(messages) do
    if message.hide == true or message.role == "system" or message.status then
      goto continue
    end

    if message.role == "tool" then
      if message.display_content then
        local line_count = vim.api.nvim_buf_line_count(self.buf)
        local start_line = line_count
        vim.api.nvim_buf_set_lines(
          self.buf,
          start_line,
          start_line,
          false,
          vim.split(message.display_content, "\n")
        )
        line_count = vim.api.nvim_buf_line_count(self.buf)
        self:highlight_tool(start_line, line_count)
        vim.api.nvim_buf_set_lines(self.buf, line_count, line_count, false, { "" })
      end
      goto continue
    end

    do
      local content = message.content
      local is_assistant = message.role == "assistant"

      local skip_header = is_assistant
        and message.turn_id
        and message.turn_id == last_assistant_turn_id

      if is_assistant and message.turn_id then
        last_assistant_turn_id = message.turn_id
      end

      if not skip_header then
        local line_count = vim.api.nvim_buf_line_count(self.buf)
        local heading = "/you"
        if is_assistant then
          heading = "/sia"
        end
        local status_text = is_assistant
            and message.turn_id
            and message.turn_id:sub(1, 6)
          or nil
        if line_count == 1 then
          vim.api.nvim_buf_set_lines(
            self.buf,
            line_count - 1,
            line_count,
            false,
            { heading, "" }
          )
          if is_assistant then
            self:_set_assistant_extmark(line_count, model, status_text)
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
          if is_assistant then
            self:_set_assistant_extmark(line_count + 2, model, status_text)
          else
            self:_set_user_extmark(line_count + 2)
          end
        end
      end

      if is_assistant then
        local reasoning = format_reasoning_lines(extract_reasoning_text(message))
        if reasoning then
          local line_count = vim.api.nvim_buf_line_count(self.buf)
          vim.api.nvim_buf_set_lines(
            self.buf,
            line_count,
            line_count,
            false,
            reasoning
          )
          vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, { "" })
        end
      end

      if content and type(content) == "string" then
        local line_count = vim.api.nvim_buf_line_count(self.buf)
        vim.api.nvim_buf_set_lines(
          self.buf,
          line_count - 1,
          line_count,
          false,
          vim.split(content, "\n")
        )
      end
    end

    ::continue::
  end
  vim.bo[self.buf].modifiable = false
  self:scroll_to_bottom()
end

--- @param model string?
--- @return integer? extmark_id
function Canvas:render_assistant_header(model)
  vim.bo[self.buf].modifiable = true
  local buf = self.buf
  local id
  if self:line_count() == 1 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "/sia", "" })
    id = self:_set_assistant_extmark(1, model)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "/sia", "" })
    id = self:_set_assistant_extmark(self:line_count() - 1, model)
  end
  vim.bo[self.buf].modifiable = false
  self:scroll_to_bottom()
  return id
end

function Canvas:clear()
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, TOOL_RESULT_NS, 0, -1)
  self:clear_temporary_text()
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

function Canvas:insert_lines_at(line, lines)
  local buf = self.buf
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, line, line, false, lines)
    self:update_progress_position()
  end
end

function Canvas:append_temporary_text_at(line, _col, text)
  if self.temporary_line == nil then
    self.temporary_line = line
  end

  if #self.temporary_content == 0 then
    self.temporary_content = { "" }
  end

  local current_line = #self.temporary_content
  self.temporary_content[current_line] = self.temporary_content[current_line] .. text

  self:update_temporary_text()
end

function Canvas:append_temporary_newline_at(line)
  if self.temporary_line == nil then
    self.temporary_line = line
  end

  table.insert(self.temporary_content, "")

  self:update_temporary_text()
end

function Canvas:update_temporary_text()
  local buf = self.buf
  if not vim.api.nvim_buf_is_loaded(buf) or self.temporary_line == nil then
    return
  end

  if self.temporary_extmark then
    pcall(vim.api.nvim_buf_del_extmark, buf, TEMPORARY_NS, self.temporary_extmark)
  end

  local virt_lines = {}
  for _, content_line in ipairs(self.temporary_content) do
    table.insert(
      virt_lines,
      { { content_line, self.opts.temporary_text_hl or "NonText" } }
    )
  end

  if #virt_lines > 0 then
    self.temporary_extmark =
      vim.api.nvim_buf_set_extmark(buf, TEMPORARY_NS, self.temporary_line, 0, {
        virt_lines = virt_lines,
        hl_eol = true,
        virt_lines_above = false,
      })
  end
end

M.Canvas = Canvas

return M
