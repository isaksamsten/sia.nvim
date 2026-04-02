--- @class sia.Capture
--- @field start_row integer 1-based, inclusive
--- @field end_row integer 1-based, inclusive
--- @field start_col integer 0-based
--- @field end_col integer 0-based

local M = {}

--- Find the smallest treesitter node matching any of the given capture names
--- that contains the cursor position.
---
--- @param query string|string[] A treesitter capture name or list of capture names (e.g. "function.outer")
--- @param buf integer? Buffer number (default: 0)
--- @param cursor integer[]? {row, col} (1-based row, 0-based col). Defaults to current cursor.
--- @return sia.Capture?
function M.treesitter(query, buf, cursor)
  buf = buf or 0
  if cursor == nil then
    local pos = vim.api.nvim_win_get_cursor(0)
    cursor = { pos[1], pos[2] }
  end

  local row = cursor[1] - 1
  local col = cursor[2]

  local ft = vim.bo[buf].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft

  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not ok or not parser then
    return nil
  end

  local ts_query = vim.treesitter.query.get(lang, "textobjects")
  if not ts_query then
    return nil
  end

  local queries = type(query) == "string" and { query } or query
  local best = nil

  for _, tree in ipairs(parser:trees()) do
    local root = tree:root()
    for id, node in ts_query:iter_captures(root, buf, row, row + 1) do
      local name = ts_query.captures[id]
      for _, q in ipairs(queries) do
        if name == q then
          local sr, sc, er, ec = node:range()
          if
            (sr < row or (sr == row and sc <= col))
            and (er > row or (er == row and ec >= col))
          then
            if best == nil then
              best = { sr, sc, er, ec }
            else
              local best_lines = best[3] - best[1]
              local cur_lines = er - sr
              if
                cur_lines < best_lines
                or (cur_lines == best_lines and (ec - sc) < (best[4] - best[2]))
              then
                best = { sr, sc, er, ec }
              end
            end
          end
        end
      end
    end
  end

  if best then
    return {
      start_row = best[1] + 1,
      start_col = best[2],
      end_row = best[3] + 1,
      end_col = best[4],
    }
  end
  return nil
end

--- Find the paragraph surrounding the cursor.
---
--- @param _buf integer? Unused, kept for signature consistency.
--- @param _cursor integer[]? Unused, kept for signature consistency.
--- @return sia.Capture?
function M.paragraph(_buf, _cursor)
  local start_pos = vim.fn.search("\\v\\s*\\S", "bn")
  local end_pos = vim.fn.search("\\v\\s*\\S", "n")

  if start_pos > 0 and end_pos > 0 then
    return {
      start_row = start_pos,
      start_col = 0,
      end_row = end_pos + 1,
      end_col = 0,
    }
  end
  return nil
end

return M

