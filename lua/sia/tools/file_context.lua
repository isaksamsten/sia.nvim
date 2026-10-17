local hashline = require("sia.hashline")
local M = {}
--- Build tagged context and the region that tracks its freshness.
--- Recovery callers can cap bytes as well as lines without marking omitted rows seen.
function M.build(conversation, path, buf, opts)
  opts = opts or {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first = math.max(1, math.min(#lines, opts.first or 1))
  local last = math.min(#lines, first + (opts.limit or 2000) - 1)
  if opts.max_bytes then
    local bytes = 0
    for i = first, last do
      local size = #tostring(i) + math.min(#lines[i], 2000) + 20
      if i > first and bytes + size > opts.max_bytes then
        last = i - 1
        break
      end
      bytes = bytes + size
    end
  end
  local rows = hashline.view(conversation, path, lines, first, last, opts.max_length or 2000)
  if opts.elisions then
    if first > 1 then
      table.insert(rows, 2, "…")
    end
    if last < #lines then
      rows[#rows + 1] = "…"
    end
  end
  local span = first == last and ("line " .. first)
    or string.format("lines %d-%d", first, last)
  local pos
  if not opts.whole_buffer then
    pos = { first, last }
  end
  return {
    content = table.concat(rows, "\n"),
    first = first,
    last = last,
    region = {
      buf = buf,
      pos = pos,
      idempotent = true,
      stale = {
        content = string.format("Previously viewed %s from %s - file was modified, use view to get current content", span, path),
        input = opts.stale_input,
      },
    },
  }
end

--- Old coordinates are only a hint: never apply a stale edit automatically.
function M.recovery(conversation, path, buf, edits)
  local anchor
  if type(edits) == "string" then
    for row in edits:gmatch("[^\n]+") do
      local n = row:match("^PUT [<>]?(%d+)") or row:match("^CUT (%d+)")
      if n then
        anchor = tonumber(n)
        break
      elseif row:match("^PUT >%$") then
        anchor = vim.api.nvim_buf_line_count(buf)
        break
      end
    end
  end
  return M.build(conversation, path, buf, {
    first = math.max(1, (anchor or 1) - 3),
    limit = 40,
    max_bytes = 8000,
    elisions = true,
    stale_input = require("sia.tools.utils").gen_clear_outdated_tool_input({ "edits" }),
  })
end

return M
