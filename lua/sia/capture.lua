local M = {}

function M.treesitter(query)
  local function get_textobject_under_cursor(opts)
    local ok, shared = pcall(require, "nvim-treesitter.textobjects.shared")
    if not ok then
      return nil
    end

    local _, pos = shared.textobject_at_point(query, nil, nil, opts.buf, { lookahead = false, lookbehind = false })
    if pos then
      return { pos[1] + 1, pos[3] + 1 }
    end

    return nil
  end

  if type(query) == "string" then
    return get_textobject_under_cursor
  else
    local function get_first_textobject_under_cursor(opts)
      for _, q in ipairs(query) do
        local ret = M.treesitter(q)(opts)
        if ret then
          return ret
        end
      end
      return nil
    end
    return get_first_textobject_under_cursor
  end
end

function M.paragraph(opts)
  local start_pos = vim.fn.search("\\v\\s*\\S", "bn")
  local end_pos = vim.fn.search("\\v\\s*\\S", "n")

  if start_pos > 0 and end_pos > 0 then
    return { start_pos, end_pos + 1 }
  else
    return nil
  end
end

return M
