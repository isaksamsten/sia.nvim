local M = {}

function M.treesitter(query)
	local function get_textobject_under_cursor(bufnr, opts)
		local ok, shared = pcall(require, "nvim-treesitter.textobjects.shared")
		if not ok then
			return false, "nvim-treesitter.textobjects is unavailable"
		end

		local _, pos = shared.textobject_at_point(query, nil, nil, bufnr, { lookahead = false, lookbehind = false })
		if pos then
			return true, { start_line = pos[1] + 1, end_line = pos[3] + 1 }
		end

		return false, "Couldn't capture " .. query
	end

	if type(query) == "string" then
		return get_textobject_under_cursor
	else
		local function get_first_textobject_under_cursor(bufnr, opts)
			for _, q in ipairs(query) do
				local ok, ret = M.treesitter(q)(bufnr, opts)
				if ok then
					return ok, ret
				end
			end
			return false, "Couldn't capture group"
		end
		return get_first_textobject_under_cursor
	end
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

function M.get_code(start_line, end_line, opts)
	local lines = {}
	for line_num = start_line, end_line do
		local line
		if opts and opts.show_line_numbers then
			line = string.format("%d: %s", line_num, vim.fn.getbufoneline(opts.bufnr or 0, line_num))
		else
			line = string.format("%s", vim.fn.getbufoneline(opts.bufnr or 0, line_num))
		end
		table.insert(lines, line)
	end

	if opts and opts.return_table == true then
		return lines
	else
		return table.concat(lines, "\n")
	end
end

function M.get_diagnostics(start_line, end_line, bufnr, opts)
	if end_line == nil then
		end_line = start_line
	end

	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local diagnostics = {}

	for line_num = start_line, end_line do
		local line_diagnostics = vim.diagnostic.get(bufnr, {
			lnum = line_num - 1,
			severity = { min = opts.min_severity or vim.diagnostic.severity.HINT },
		})

		if next(line_diagnostics) ~= nil then
			for _, diagnostic in ipairs(line_diagnostics) do
				table.insert(diagnostics, {
					line_number = line_num,
					message = diagnostic.message,
					severity = vim.diagnostic.severity[diagnostic.severity],
				})
			end
		end
	end

	return diagnostics
end
return M
