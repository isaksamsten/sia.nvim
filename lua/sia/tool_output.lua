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
--- @return string
function M.limit(text)
  text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  local clipped = #text > 32000
  if clipped then
    text = byte_prefix(text, 32000)
  end
  local lines = vim.split(text, "\n", { plain = true })
  while lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines > 200 then
    lines = vim.list_slice(lines, 1, 200)
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
      if part.type == "text" then
        table.insert(parts, part.text)
      end
    end
  end
  return { text = table.concat(parts, "\n"), ft = "text" }
end

--- Normalize explicitly supplied previews only. Tools opt in through preview,
--- result.preview, or summary.detail. Keep this serializable for history/redraw.
--- @param result sia.ToolResult
function M.complete(result)
  if not result.summary then
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
    summary.detail = { text = preview.text, ft = preview.ft or "text" }
  end
  if summary.detail then
    summary.detail.text = M.limit(summary.detail.text)
    result.summary = summary
  end
  result.preview = nil
end

return M
