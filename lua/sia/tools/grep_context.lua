local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local file_context = require("sia.tools.file_context")
local M = {}
local MAX_MATCHES, MAX_BYTES = 100, 24000

local function load_buffer(path)
  local buf = utils.ensure_file_is_loaded(path, { read_only = true, listed = false })
  if buf and not vim.bo[buf].modified then
    -- Use Neovim's reload machinery, preserving modified buffers and tracker events.
    local autoread = vim.bo[buf].autoread
    vim.bo[buf].autoread = true
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent! checktime " .. buf)
    end)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].autoread = autoread
    else
      return nil
    end
  end
  return buf
end

--- rg locates candidates; only matching buffer text can become editable context.
function M.build(events, args, conversation)
  local groups, order, total = {}, {}, 0
  for _, event in ipairs(events) do
    local ok, entry = pcall(vim.json.decode, event)
    if ok and entry.type == "match" then
      local data = entry.data
      local file = data.path.text
      if file and data.lines.text and data.line_number then
        total = total + 1
        if not groups[file] then
          groups[file] = {}
          order[#order + 1] = file
        end
        groups[file][#groups[file] + 1] = data
      end
    end
  end
  if total == 0 then
    return { content = "No matches found.", summary = "No matches found for `" .. args.pattern .. "`" }
  end
  table.sort(order, function(a, b)
    local function mtime(file)
      local path = tool_utils.resolve_workspace_path(file, conversation.workspace)
      local stat = vim.uv.fs_stat(path)
      return stat and stat.mtime.sec or 0
    end
    local a_time, b_time = mtime(a), mtime(b)
    return a_time == b_time and a < b or a_time > b_time
  end)
  local output, preview = {}, {}
  local accepted, selected, bytes, files, skipped = 0, 0, 0, 0, 0
  for _, file in ipairs(order) do
    if selected >= MAX_MATCHES or bytes >= MAX_BYTES then break end
    local path = tool_utils.resolve_workspace_path(file, conversation.workspace)
    local buf = load_buffer(path)
    local lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local windows = {}
    table.sort(groups[file], function(a, b) return a.line_number < b.line_number end)
    for _, match in ipairs(groups[file]) do
      if selected >= MAX_MATCHES then break end
      selected = selected + 1
      local text = match.lines.text:gsub("\n$", "")
      local matched = vim.split(text, "\n", { plain = true })
      local valid = lines ~= nil
      for i, line in ipairs(matched) do
        if buf and vim.bo[buf].fileformat == "dos" then line = line:gsub("\r$", "") end
        if not lines or lines[match.line_number + i - 1] ~= line then valid = false end
      end
      if valid then
        accepted = accepted + 1
        local first = math.max(1, match.line_number - 1)
        local last = math.min(#lines, match.line_number + #matched - 1 + 3)
        local previous = windows[#windows]
        if previous and first <= previous[2] + 1 then
          previous[2] = math.max(previous[2], last)
        else
          windows[#windows + 1] = { first, last }
        end
      else
        skipped = skipped + 1
      end
    end
    local shown_file = false
    for _, window in ipairs(windows) do
      if bytes >= MAX_BYTES then break end
      local context = file_context.build(conversation, path, buf, {
        first = window[1], limit = window[2] - window[1] + 1,
        max_bytes = MAX_BYTES - bytes, max_length = 200,
      })
      local rows = vim.split(context.content, "\n", { plain = true })
      if not shown_file then
        output[#output + 1] = rows[1]
        preview[#preview + 1] = file
        shown_file = true
        files = files + 1
      else
        output[#output + 1] = "…"
      end
      for i = 2, #rows do
        output[#output + 1] = rows[i]
        preview[#preview + 1] = "  " .. rows[i]
      end
      bytes = bytes + #context.content
      if context.last < window[2] then
        output[#output + 1] = "…"
        bytes = MAX_BYTES
        break
      end
    end
  end
  local note
  if skipped > 0 then
    note = string.format("Omitted %d disk search result(s): the buffer differs at those locations or could not be loaded. Use view for current buffer contents.", skipped)
    output[#output + 1] = note
    preview[#preview + 1] = note
  end
  if selected < total or bytes >= MAX_BYTES then
    note = "Results limited to 100 candidate matches and bounded context; narrow the search for more."
    output[#output + 1] = note
    preview[#preview + 1] = note
  end
  local header = string.format("Search results: %d verified match(es) in %d file(s).", accepted, files)
  table.insert(output, 1, header)
  return {
    content = table.concat(output, "\n"),
    summary = header,
    preview = #preview > 0 and { text = table.concat(preview, "\n"), ft = "text" } or nil,
  }
end

return M
