local M = {}

-- Cache inline captures, not window-specific widths or resolved highlight colors.
local cache = {}
local cache_size = 0

local function captures(text)
  if cache[text] then
    return cache[text]
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown_inline")
  if not ok then
    return {}
  end
  local query = vim.treesitter.query.get("markdown_inline", "highlights")
  if not query then
    return {}
  end
  local ranges = {}
  for id, node, metadata in query:iter_captures(parser:parse()[1]:root(), text, 0, 1) do
    local name = query.captures[id]
    local _, first, _, last = node:range()
    local conceal = (metadata[id] or {}).conceal or metadata.conceal
    if conceal ~= nil or name:match("^markup%.") then
      table.insert(ranges, {
        first = first,
        last = last,
        conceal = conceal,
        group = name:match("^markup%.") and ("@" .. name .. ".markdown_inline") or nil,
      })
    end
  end
  if cache_size >= 128 then
    cache, cache_size = {}, 0
  end
  cache[text] = ranges
  cache_size = cache_size + 1
  return ranges
end

--- Render inline Markdown in a closed fold without splitting UTF-8 characters.
--- @param text string
--- @param max_width integer Display cells, excluding the line-count suffix.
--- @param highlights string[]? Base groups, before Markdown formatting.
--- @return table[]
function M.render(text, max_width, highlights)
  highlights = highlights or { "SiaFolded" }
  local ranges = captures(text)
  local chunks = {}
  local column, displayed = 0, ""
  local last_key
  for _, char in ipairs(vim.fn.split(text, [[\zs]])) do
    local groups = vim.list_extend({}, highlights)
    local concealed
    for _, range in ipairs(ranges) do
      if column >= range.first and column < range.last then
        if range.conceal ~= nil then
          concealed = column == range.first and range.conceal or ""
        elseif range.group then
          table.insert(groups, range.group)
        end
      end
    end
    column = column + #char
    local visible = concealed ~= nil and concealed or char
    if visible ~= "" then
      if vim.fn.strdisplaywidth(displayed .. visible) > max_width then
        table.insert(
          chunks,
          { "…", #highlights == 1 and highlights[1] or highlights }
        )
        break
      end
      displayed = displayed .. visible
      local key = table.concat(groups, "\0")
      if key == last_key then
        chunks[#chunks][1] = chunks[#chunks][1] .. visible
      else
        table.insert(chunks, { visible, #groups == 1 and groups[1] or groups })
        last_key = key
      end
    end
  end
  return chunks
end

--- @return table[]
function M.foldtext()
  local foldstart = vim.v.foldstart
  local foldend = vim.v.foldend
  local num_lines = foldend - foldstart + 1

  local first_line = vim.fn.getline(foldstart)
  if first_line == "  ▼ Details" then
    local body_lines, fence = 0, nil
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, foldstart, foldend, false)) do
      if not fence then
        fence = line:match("^(```+)[%w_+%-]*$")
      elseif line == fence then
        fence = nil
      else
        body_lines = body_lines + 1
      end
    end
    return {
      {
        string.format(
          "  ▶ Details · %d %s",
          body_lines,
          body_lines == 1 and "line" or "lines"
        ),
        "SiaFolded",
      },
    }
  end
  local max_width = math.max(40, vim.api.nvim_win_get_width(0) - 20)
  local groups = { "SiaFolded", "SiaReasoning" }
  local chunks = M.render(first_line, max_width, groups)
  local suffix =
    string.format(" · %d %s", num_lines, num_lines == 1 and "line" or "lines")
  local last = chunks[#chunks]
  if last and vim.deep_equal(last[2], groups) then
    last[1] = last[1] .. suffix
  else
    table.insert(chunks, { suffix, groups })
  end
  table.insert(chunks, 1, { "· ", { "SiaAssistantMarker", "SiaReasoning" } })
  return chunks
end

return M
