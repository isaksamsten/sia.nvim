local M = {}

local function byte_prefix(text, limit)
  local next_byte = limit + 1
  while next_byte > 1 do
    local byte = text:byte(next_byte)
    if not byte or byte < 128 or byte >= 192 then
      break
    end
    next_byte = next_byte - 1
  end
  return text:sub(1, next_byte - 1)
end

--- Capture an approval preview before execution, without opening a window.
--- Preview failures must never prevent the tool from running.
--- @param content string[]|fun(buf:integer):integer?
--- @return sia.ToolPreview?
function M.capture(content)
  if type(content) == "table" then
    return { text = table.concat(content, "\n"), ft = "text" }
  end
  if type(content) ~= "function" then
    return nil
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, preview = pcall(function()
    content(buf)
    return {
      text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      ft = vim.bo[buf].filetype,
    }
  end)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  return ok and preview or nil
end

--- Bound and sanitize plain text so tool output cannot alter the transcript layout.
--- @param text string
--- @param byte_limit integer?
--- @param line_limit integer?
--- @return string
function M.limit(text, byte_limit, line_limit)
  byte_limit, line_limit = byte_limit or 32000, line_limit or 200
  text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  local clipped = #text > byte_limit
  if clipped then
    text = byte_prefix(text, byte_limit)
  end
  local lines = vim.split(text, "\n", { plain = true })
  while lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines > line_limit then
    lines = vim.list_slice(lines, 1, line_limit)
    clipped = true
  end
  for i, line in ipairs(lines) do
    if #line > 1000 then
      lines[i] = byte_prefix(line, 1000) .. "…"
    end
  end
  if clipped then
    table.insert(lines, "… preview truncated")
  end
  return table.concat(lines, "\n")
end

--- Extract only text from a result, never binary/image payloads.
--- @param content sia.Content
--- @return sia.ToolPreview
function M.from_content(content)
  local parts = {}
  if type(content) == "string" then
    parts = { content }
  elseif type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "string" then
        table.insert(parts, part)
      elseif part.type == "text" then
        table.insert(parts, part.text)
      end
    end
  end
  return { text = table.concat(parts, "\n"), ft = "text" }
end

--- Accept one fenced section or an ordered list of independently typed sections.
--- @param detail sia.ToolDetails
--- @return sia.ToolPreview[]
function M.sections(detail)
  return detail.text ~= nil and { detail } or detail
end

--- Share the existing preview budget across all sections.
--- @param detail sia.ToolDetails
--- @return sia.ToolDetails?
local function normalize_details(detail)
  local sections = {}
  local bytes, lines = 32000, 200
  for _, section in ipairs(M.sections(detail)) do
    if bytes <= 0 or lines <= 0 then
      local last = sections[#sections]
      if last and not last.text:find("… preview truncated", 1, true) then
        last.text = last.text .. "\n… preview truncated"
      end
      break
    end
    local text = M.limit(section.text, bytes, lines)
    if text ~= "" then
      table.insert(sections, { text = text, ft = section.ft })
      bytes = bytes - #text
      lines = lines - #vim.split(text, "\n", { plain = true })
    end
  end
  if #sections == 0 then
    return nil
  end
  return detail.text ~= nil and sections[1] or sections
end

--- Normalize explicitly supplied previews only. Tools opt in through preview,
--- result.preview, or summary.detail. Keep this serializable for history/redraw.
--- @param result sia.ToolResult
function M.complete(result)
  if result.kind == "cancelled" then
    result.preview = nil
  end
  if not result.summary then
    result.preview = nil
    return
  end
  local summary = type(result.summary) == "string" and { header = result.summary }
    or vim.deepcopy(result.summary)
  if summary.detail == nil and result.preview then
    local header = summary.header:lower()
    local failed = header:match("^[^%w]*failed%f[%W]")
      or header:match("^[^%w]*cancelled%f[%W]")
    local preview = result.preview
    if result.ephemeral or failed then
      preview = M.from_content(result.content)
    end
    summary.detail = vim.deepcopy(preview)
    for _, section in ipairs(M.sections(summary.detail)) do
      section.ft = section.ft or "text"
    end
  end
  if summary.detail then
    summary.detail = normalize_details(summary.detail)
    result.summary = summary
  end
  result.preview = nil
end

--- Fill accidental omissions without changing explicitly hidden results or model content.
--- @param result sia.ToolResult
--- @param name string
function M.ensure_summary(result, name)
  if result.summary ~= nil then
    return
  end
  local text = M.from_content(result.content).text
  local first = text:match("[^\r\n]+") or ""
  local label = name:gsub("_", " ")
  if first:match("^OPERATION DECLINED") then
    result.summary = "Cancelled " .. label
  elseif first:match("^Error:") or first:match("^LSP Error:") or result.kind == "failed"
    or (result.ephemeral and not first:match("^No "))
  then
    local reason = first:gsub("^[^:]+:%s*", "")
    result.summary = "Failed " .. label .. (reason ~= "" and ": " .. reason or "")
  elseif first:match("^No ") or first:match("^Nothing ") then
    result.summary = first
  else
    result.summary = "Completed " .. label
  end
  -- Keep a fallback header on one line, bounded even for verbose server errors.
  result.summary = M.limit(result.summary):match("[^\n]*")
end

return M
