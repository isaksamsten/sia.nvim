local M = {}

function M.treesitter(query)
	local function get_textobject_under_cursor(bufnr, opts)
		local ok, shared = pcall(require, "nvim-treesitter.textobjects.shared")
		if ok then
			local _, textobject =
				shared.textobject_at_point(query, nil, nil, bufnr, { lookahead = false, lookbehind = false })

			if textobject then
				return true, { start_line = textobject[1] + 1, end_line = textobject[3] + 1 }
			end
			return false, "Couldn't capture " .. query
		end
		return false, "nvim-treesitter.textobjects is unavailiable"
	end
	return get_textobject_under_cursor
end

function M.paragraph(bufnr, opts)
	local start_pos = vim.fn.search("\\v\\s*\\S", "bn")
	local end_pos = vim.fn.search("\\v\\s*\\S", "n")

	if start_pos > 0 and end_pos > 0 then
		return true, { start_line = start_pos, end_line = end_pos + 1 }
	else
		return false, "Unable to locate a paragraph"
	end
end

return M
