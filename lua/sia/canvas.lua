local M = {}

local CHAT_NS = vim.api.nvim_create_namespace("sia_chat")
local PROGRESS_NS = vim.api.nvim_create_namespace("sia_chat")
local TEMPORARY_NS = vim.api.nvim_create_namespace("sia_chat_temporary")
local TOOL_PREVIEW_NS = vim.api.nvim_create_namespace("sia_chat_tool_preview")
local ASSISTANT_TEXT_NS = vim.api.nvim_create_namespace("sia_chat_assistant_text")
local TOOL_RESULT_NS = vim.api.nvim_create_namespace("sia_chat_tool_result")
local REASONING_META_PREFIX = ">| "
local TOOL_META_PREFIX = ">! "
local DETAILS_LABEL = "  + Details"

--- @param summary sia.ToolSummary
--- @return sia.ToolSummaryParts
local function normalize_tool_summary(summary)
  if type(summary) == "string" then
    return { header = summary }
  end

  return summary
end

--- @param lines string[]
--- @return string[]
local function trim_trailing_empty(lines)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

--- @param details string
--- @param ft string?
--- @return string[]?
local function format_tool_detail_lines(details, ft)
  local lines = trim_trailing_empty(vim.split(details, "\n", { plain = true }))
  if vim.tbl_isempty(lines) then
    return nil
  end
  -- A longer fence keeps literal fences in command output inside the preview.
  local length = 3
  for _, line in ipairs(lines) do
    for ticks in line:gmatch("`+") do
      length = math.max(length, #ticks + 1)
    end
  end
  local fence = string.rep("`", length)
  local language = (ft or "text"):match("^[%w_+%-]+$") or "text"
  table.insert(lines, 1, fence .. language)
  table.insert(lines, 1, DETAILS_LABEL)
  table.insert(lines, fence)
  return lines
end

--- @param status "pending"|"done"|"running"
--- @param summary sia.ToolSummary
--- @return string[]?
local function format_tool_summary_lines(status, summary)
  summary = normalize_tool_summary(summary)
  local lines = vim.split(summary.header, "\n", { plain = true })
  for index, line in ipairs(lines) do
    lines[index] = "• " .. line
  end
  if status == "done" and summary.detail then
    local detail_lines =
      format_tool_detail_lines(summary.detail.text, summary.detail.ft)
    if detail_lines then
      vim.list_extend(lines, detail_lines)
    end
  end

  return lines
end

--- @param line string
--- @return "reasoning"|"tool"|nil
local function meta_line_kind(line)
  if line == ">|" or line:match("^>| ") ~= nil then
    return "reasoning"
  end
  if line == ">!" or line:match("^>! ") ~= nil then
    return "tool"
  end
  return nil
end

--- @param line string
--- @param kind "reasoning"|"tool"
--- @return string
local function strip_meta_prefix(line, kind)
  if kind == "reasoning" then
    return (line:gsub("^>|%s?", ""))
  end
  return (line:gsub("^>!%s?", ""))
end

--- @param content string
--- @return string[]?
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
      table.insert(formatted, REASONING_META_PREFIX)
    else
      table.insert(formatted, REASONING_META_PREFIX .. line)
    end
  end

  return formatted
end

--- @class sia.CanvasOpts
--- @field temporary_text_hl string?

--- @class sia.Canvas
--- @field buf integer
--- @field progress_extmark integer?
--- @field temporary_extmark integer?
--- @field temporary_content string[]
--- @field temporary_line integer?
--- @field footer_marks table<string, integer>
--- @field turn_usage table<string, sia.Usage>
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
    footer_marks = {},
    turn_usage = {},
  }
  setmetatable(obj, self)
  return obj
end

--- Mark the start of an assistant text block without altering Markdown content.
--- @param line integer Zero-based buffer row.
function Canvas:mark_assistant_text(line)
  vim.api.nvim_buf_set_extmark(self.buf, ASSISTANT_TEXT_NS, line, 0, {
    virt_text = { { "· ", "SiaAssistantMarker" } },
    virt_text_pos = "inline",
    right_gravity = true,
    hl_mode = "combine",
  })
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
--- @param summary sia.ToolSummary?
function Canvas:highlight_tool(line, end_line, summary)
  local header_lines = summary
      and #vim.split(normalize_tool_summary(summary).header, "\n", { plain = true })
    or end_line - line
  -- Only the action header is decorated. Markdown injections highlight the body.
  vim.api.nvim_buf_set_extmark(self.buf, TOOL_RESULT_NS, line, 0, {
    end_line = line + header_lines,
    end_right_gravity = false,
    priority = 110,
    hl_mode = "combine",
    hl_eol = true,
    hl_group = "SiaToolResult",
  })
  if type(summary) ~= "table" or not summary.detail then
    return
  end
  local details = format_tool_detail_lines(summary.detail.text, summary.detail.ft)
  local fence_line = line + header_lines
  if details and fence_line + #details <= end_line then
    vim.api.nvim_buf_set_extmark(self.buf, TOOL_PREVIEW_NS, fence_line, 0, {
      end_row = fence_line + #details,
      end_right_gravity = false,
      right_gravity = false,
    })
  end
end

--- @param tool_renders table<string, sia.engine.Status>
--- @param tool_order string[]
--- @return string[], { start: integer, finish: integer, summary: sia.ToolSummary }[]
local function build_tool_block(tool_renders, tool_order)
  local lines = {}
  local highlights = {}

  for _, key in ipairs(tool_order) do
    local render = tool_renders[key]
    if render and render.summary then
      local block_lines = format_tool_summary_lines(render.status, render.summary)
      if block_lines then
        local start = #lines
        vim.list_extend(lines, block_lines)
        table.insert(highlights, {
          start = start,
          finish = #lines,
          summary = render.summary,
        })
      end
    end
  end

  if #lines > 0 then
    table.insert(lines, "")
  end

  return lines, highlights
end

--- @param start_line integer?
--- @param end_line integer?
function Canvas:clear_tool_highlights(start_line, end_line)
  for _, namespace in ipairs({ TOOL_PREVIEW_NS, TOOL_RESULT_NS }) do
    if start_line == nil and end_line == nil then
      vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
    else
      -- Namespace range clearing also removes ranges that end at the start
      -- boundary. Adjacent tool blocks must retain those preceding marks.
      local marks = vim.api.nvim_buf_get_extmarks(self.buf, namespace, 0, -1, {})
      for _, mark in ipairs(marks) do
        if mark[2] >= (start_line or 0) and (not end_line or end_line == -1 or mark[2] < end_line) then
          vim.api.nvim_buf_del_extmark(self.buf, namespace, mark[1])
        end
      end
    end
  end
end

-- Text changes can evaluate foldexpr before preview extmarks exist. Invalidate
-- cached levels once all preview ranges have been installed, in every window.
function Canvas:refresh_folds()
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    if vim.wo[win].foldmethod == "expr" then
      vim.wo[win].foldexpr = vim.wo[win].foldexpr
    end
  end
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

--- @param lnum integer
--- @return string|integer
function M.blockquote_foldexpr(lnum)
  local row = lnum - 1
  local marks = vim.api.nvim_buf_get_extmarks(0, TOOL_PREVIEW_NS, { row, 0 }, 0, {
    details = true,
    limit = 1,
  })
  local mark = marks[1]
  if mark and row < mark[4].end_row then
    -- Fold the details label, fences, and body; keep the action header outside.
    return row == mark[2] and ">1" or 1
  end
  local line = vim.fn.getline(lnum)
  local prev = lnum > 1 and vim.fn.getline(lnum - 1) or ""
  local line_kind = meta_line_kind(line)
  local prev_kind = meta_line_kind(prev)

  if line_kind then
    if line_kind ~= prev_kind then
      return ">1"
    end
    return 1
  end

  return 0
end

--- @return [string, string][]
function M.blockquote_foldtext()
  local foldstart = vim.v.foldstart
  local foldend = vim.v.foldend
  local num_lines = foldend - foldstart + 1

  local first_line = vim.fn.getline(foldstart)
  if first_line == DETAILS_LABEL then
    return {
      {
        string.format("  + Show details… · %d %s", math.max(0, num_lines - 3), num_lines == 4 and "line" or "lines"),
        "SiaFolded",
      },
    }
  end
  local kind = meta_line_kind(first_line)
  local preview = kind and strip_meta_prefix(first_line, kind) or first_line
  local max_width = math.max(40, vim.api.nvim_win_get_width(0) - 20)
  if #preview > max_width then
    preview = preview:sub(1, max_width) .. "…"
  end

  return { { string.format("%s  (%d lines)", preview, num_lines), "SiaFolded" } }
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

--- Keep an empty write position, optionally separated from the previous block.
--- @param separate boolean
--- @return integer Zero-based row.
function Canvas:ensure_placeholder(separate)
  local count = self:line_count()
  local lines = vim.api.nvim_buf_get_lines(self.buf, math.max(0, count - 2), count, false)
  local last = lines[#lines]
  local occupied = false
  if last == "" then
    local marks = vim.api.nvim_buf_get_extmarks(
      self.buf, CHAT_NS, { count - 1, 0 }, { count - 1, 0 }, { details = true }
    )
    local footer_ids = {}
    for _, id in pairs(self.footer_marks) do
      footer_ids[id] = true
    end
    for _, mark in ipairs(marks) do
      if footer_ids[mark[1]] then
        occupied = true
        break
      end
    end
  end
  if last ~= "" or occupied then
    self:insert_lines_at(count, separate and { "", "" } or { "" })
  elseif separate and count > 1 and lines[#lines - 1] ~= "" then
    self:insert_lines_at(count, { "" })
  end
  return self:line_count() - 1
end

--- @param line integer Zero-based row below the assistant's content.
--- @param _model string?
--- @param turn_id string
--- @param usage sia.Usage?
--- @param id integer?
function Canvas:set_assistant_footer(line, _model, turn_id, usage, id)
  -- Use an ordinary blank row so folds and concealed Markdown fences cannot
  -- hide the footer together with the last line of assistant content.
  if vim.api.nvim_buf_get_lines(self.buf, line, line + 1, false)[1] ~= "" then
    self:insert_lines_at(line + 1, { "" })
    line = line + 1
  end
  local previous = self.footer_marks[turn_id]
  if id and previous and previous ~= id then
    vim.api.nvim_buf_del_extmark(self.buf, CHAT_NS, previous)
  end
  if usage then
    self.turn_usage[turn_id] = vim.deepcopy(usage)
  end
  usage = usage or self.turn_usage[turn_id]
  local chunks = {}
  if usage and usage.total_time then
    table.insert(chunks, { string.format("  Worked for %ds", math.floor(usage.total_time + 0.5)), "SiaUsage" })
  end
  local prefix = #chunks > 0 and " · #" or "  #"
  table.insert(chunks, { prefix .. turn_id:sub(1, 6), "SiaStatus" })
  self.footer_marks[turn_id] = vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line, 0, {
    id = id or previous,
    virt_text = chunks,
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

--- @param id integer?
--- @param opts {model:string?, usage:sia.Usage?, turn_id:string}
function Canvas:update_assistant_footer(id, opts)
  self:set_assistant_footer(self:line_count() - 1, opts.model, opts.turn_id, opts.usage, id)
end

--- @param line integer Zero-based first row of the query.
--- @param count integer
function Canvas:highlight_user_query(line, count)
  vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, line, 0, {
    end_row = line + count,
    hl_mode = "combine",
    hl_eol = true,
    hl_group = "SiaUser",
    end_right_gravity = false,
  })
  for row = line, line + count - 1 do
    vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, row, 0, {
      virt_text = { { "> ", "SiaUser" } },
      virt_text_pos = "inline",
      right_gravity = true,
    })
  end
end

--- @param message sia.Entry
--- @return boolean
local function is_renderable_message(message)
  return message.hide ~= true and message.role ~= "system" and not message.dropped
end

--- @param messages sia.Entry[]
--- @param model string?
function Canvas:render_messages(messages, model)
  vim.bo[self.buf].modifiable = true
  local previous_role
  local pending_turn
  local function finish_turn()
    if pending_turn then
      self:set_assistant_footer(self:line_count() - 1, model, pending_turn)
      pending_turn = nil
    end
  end
  for _, message in ipairs(messages) do
    if not is_renderable_message(message) then
      goto continue
    end
    if pending_turn and (message.role == "user" or message.turn_id ~= pending_turn) then
      finish_turn()
    end
    local content = message.content
    if message.role == "tool" then
      if not message.summary then
        goto continue
      end
      local lines = format_tool_summary_lines("done", message.summary)
      local row = self:ensure_placeholder(previous_role == "user")
      vim.api.nvim_buf_set_lines(self.buf, row, row + 1, false, lines)
      self:highlight_tool(row, row + #lines, message.summary)
      self:insert_lines_at(self:line_count(), { "" })
    elseif message.role == "user" then
      if type(content) ~= "string" or content == "" then
        goto continue
      end
      local row = self:ensure_placeholder(true)
      local lines = vim.split(content, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(self.buf, row, row + 1, false, lines)
      self:highlight_user_query(row, #lines)
    elseif message.role == "assistant" then
      local reasoning = message.reasoning and format_reasoning_lines(message.reasoning.text)
      local text = type(content) == "string" and content:gsub("^\n+", "") or ""
      if not reasoning and text == "" then
        goto continue
      end
      local row = self:ensure_placeholder(previous_role ~= "tool")
      if reasoning then
        vim.api.nvim_buf_set_lines(self.buf, row, row + 1, false, reasoning)
        self:insert_lines_at(self:line_count(), text ~= "" and { "", "" } or { "" })
        row = self:line_count() - 1
      end
      if text ~= "" then
        vim.api.nvim_buf_set_lines(self.buf, row, row + 1, false, vim.split(text, "\n"))
        self:mark_assistant_text(row)
      end
    end
    if message.role ~= "user" and message.turn_id then
      pending_turn = message.turn_id
    end
    previous_role = message.role
    ::continue::
  end
  finish_turn()
  self:refresh_folds()
  vim.bo[self.buf].modifiable = false
  self:scroll_to_bottom()
end

--- @param position [integer, integer]
--- @param previous_line_count integer
--- @param tool_renders table<string, sia.engine.Status>
--- @param tool_order string[]
--- @param opts { preserve_placeholder?: boolean }?
--- @return integer
function Canvas:update_tool_block(
  position,
  previous_line_count,
  tool_renders,
  tool_order,
  opts
)
  if not position or #position == 0 then
    return previous_line_count
  end

  opts = opts or {}

  local line = position[1]
  local lines, highlights = build_tool_block(tool_renders, tool_order)
  local previous_end = line + previous_line_count
  if #lines == 0 then
    local replacement = opts.preserve_placeholder and { "" } or {}
    self:clear_tool_highlights(line, previous_end)
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, line, previous_end, false, replacement)
    self:refresh_folds()
    return #replacement
  end

  self:clear_tool_highlights(line, previous_end)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, line, previous_end, false, lines)
  for _, highlight in ipairs(highlights) do
    self:highlight_tool(
      line + highlight.start,
      line + highlight.finish,
      highlight.summary
    )
  end
  self:refresh_folds()
  return #lines
end

--- @return integer extmark_id
function Canvas:begin_assistant_turn()
  vim.bo[self.buf].modifiable = true
  local row = self:ensure_placeholder(true)
  local id = vim.api.nvim_buf_set_extmark(self.buf, CHAT_NS, row, 0, { right_gravity = true })
  self:scroll_to_bottom()
  return id
end

function Canvas:clear()
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
  vim.bo[self.buf].modifiable = false
  self:clear_tool_highlights()
  vim.api.nvim_buf_clear_namespace(self.buf, ASSISTANT_TEXT_NS, 0, -1)
  self:clear_temporary_text()
  vim.api.nvim_buf_clear_namespace(self.buf, PROGRESS_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.buf, CHAT_NS, 0, -1)
  self.footer_marks = {}
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

function Canvas:remove_line_at(line)
  local buf = self.buf
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, line, line + 1, false, {})
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
